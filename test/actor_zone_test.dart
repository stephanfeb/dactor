import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:test/test.dart';

final _log = <String>[];
final _never = Completer<void>();

/// An actor whose behaviour is chosen by the message it receives.
class _Probe extends Actor {
  final String name;
  _Probe(this.name);

  @override
  FutureOr<void> preStart() {
    _log.add('start:$name');
  }

  @override
  Future<void> onMessage(dynamic message) async {
    switch (message) {
      case 'lost-future':
        // Nothing awaits this, so the handler itself completes normally.
        Future<void>.delayed(const Duration(milliseconds: 5))
            .then((_) => throw StateError('lost'));
      case 'bad-timer':
        Timer(const Duration(milliseconds: 5), () => throw StateError('tick'));
      case 'slow':
        await Future<void>.delayed(const Duration(milliseconds: 40));
        _log.add('$name:slow-done');
      case 'hang':
        try {
          await _never.future;
          _log.add('$name:resumed');
        } finally {
          _log.add('$name:finally');
        }
      case 'leave-work-behind':
        Timer.periodic(
            const Duration(milliseconds: 5), (_) => _log.add('$name:tick'));
        Future<void>.delayed(const Duration(milliseconds: 30))
            .then((_) => _log.add('$name:late'));
      case 'boom':
        throw StateError('boom');
      case 'stop-self':
        await context.system.stop(context.self);
        _log.add('$name:after-self-stop');
      case 'spawn-twice':
        await context.spawn('dup', () => _Probe('dup'));
        try {
          await context.spawn('dup', () => _Probe('dup'));
        } on ArgumentError {
          _log.add('$name:caught-duplicate');
        }
      case ActorRef target:
        await context.system.stop(target);
        _log.add('$name:stopped-target');
      default:
        _log.add('$name:$message');
    }
  }

  @override
  void postStop() => _log.add('stop:$name');
}

class _Sup extends SupervisorActor {
  final List<String> kids;
  _Sup(this.kids)
      : super(
            OneForOneStrategy(decider: (e, s) => SupervisionDecision.restart));

  @override
  FutureOr<void> preStart() async {
    for (final kid in kids) {
      await supervise(kid, () => _Probe(kid));
    }
  }

  @override
  void postStop() => _log.add('stop:sup');
}

SupervisionStrategy _restart() =>
    OneForOneStrategy(decider: (e, s) => SupervisionDecision.restart);

Future<void> _settle([int ms = 60]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void _tell(ActorRef ref, Object payload) =>
    ref.tell(LocalMessage(payload: payload));

void main() {
  late LocalActorSystem system;
  late InMemoryMetricsCollector metrics;

  LocalActorSystem build({Duration? stopTimeout}) =>
      LocalActorSystem(ActorSystemConfig(
          metricsCollector: metrics,
          logCollector: const NoOpLogCollector(),
          stopTimeout: stopTimeout));

  setUp(() {
    _log.clear();
    metrics = InMemoryMetricsCollector();
    system = build();
  });

  tearDown(() => system.shutdown());

  group('errors that nothing caught belong to the actor', () {
    test('an unawaited future that fails restarts the actor', () async {
      final a =
          await system.spawn('a', () => _Probe('a'), supervision: _restart());
      final b = await system.spawn('b', () => _Probe('b'));
      _tell(a, 'lost-future');
      await _settle();
      _tell(a, 'hello');
      _tell(b, 'hello');
      await _settle(20);

      expect(_log,
          ['start:a', 'start:b', 'stop:a', 'start:a', 'a:hello', 'b:hello']);
      expect(metrics.getCounter('actors.failed'), 1);
      expect(metrics.getCounter('actors.restarted'), 1);
    });

    test('a timer callback that throws stops an unsupervised actor', () async {
      final a = await system.spawn('a', () => _Probe('a'));
      _tell(a, 'bad-timer');
      await _settle();
      expect(a.isAlive, isFalse);
      expect(_log, ['start:a', 'stop:a']);
    });
  });

  group('graceful stop', () {
    test('lets the handler in flight finish before postStop', () async {
      final a = await system.spawn('a', () => _Probe('a'));
      _tell(a, 'slow');
      _tell(a, 'never-delivered');
      await _settle(5);
      await system.stop(a);
      expect(_log, ['start:a', 'a:slow-done', 'stop:a']);
    });

    test('kills a handler that outlasts the stop timeout', () async {
      await system.shutdown();
      system = build(stopTimeout: const Duration(milliseconds: 40));
      final a = await system.spawn('a', () => _Probe('a'));
      _tell(a, 'hang');
      await _settle(5);

      final sw = Stopwatch()..start();
      await system.stop(a);
      expect(sw.elapsedMilliseconds, inInclusiveRange(30, 400));
      expect(a.isAlive, isFalse);
      expect(metrics.getCounter('actors.stop_timed_out'), 1);
      // postStop ran; the suspended handler, including its finally, did not.
      expect(_log, ['start:a', 'stop:a']);
    });

    test('an actor that stops itself is cut off at that await', () async {
      final a = await system.spawn('a', () => _Probe('a'));
      _tell(a, 'stop-self');
      await _settle();
      expect(a.isAlive, isFalse);
      expect(_log, ['start:a', 'stop:a']);
    });

    test('a child can stop its own parent without waiting on itself', () async {
      final sup = await system.spawn('sup', () => _Sup(['kid']));
      final sw = Stopwatch()..start();
      _tell(system.getActor('sup/kid')!, sup);
      await _settle(100);
      expect(sup.isAlive, isFalse);
      expect(system.getActor('sup/kid'), isNull);
      expect(_log, ['start:kid', 'stop:kid', 'stop:sup']);
      expect(sw.elapsedMilliseconds, lessThan(1000));
    });

    test('one actor stopping another waits for the target only', () async {
      final a = await system.spawn('a', () => _Probe('a'));
      final b = await system.spawn('b', () => _Probe('b'));
      _tell(b, 'slow');
      await _settle(5);
      _tell(a, b);
      await _settle(100);
      expect(_log, [
        'start:a',
        'start:b',
        'b:slow-done',
        'stop:b',
        'a:stopped-target',
      ]);
    });
  });

  group('kill', () {
    test('is immediate and the suspended handler never resumes', () async {
      final a = await system.spawn('a', () => _Probe('a'));
      _tell(a, 'hang');
      await _settle(5);
      system.kill(a);
      expect(a.isAlive, isFalse);
      expect(system.getActor('a'), isNull);
      await _settle();
      expect(_log, ['start:a', 'stop:a']);
      expect(metrics.getCounter('actors.killed'), 1);

      // The id is free and the system is still healthy.
      final again = await system.spawn('a', () => _Probe('a2'));
      _tell(again, 'hi');
      await _settle(10);
      expect(_log.last, 'a2:hi');
    });

    test('takes the children too, last started first', () async {
      final sup = await system.spawn('sup', () => _Sup(['k1', 'k2']));
      _tell(system.getActor('sup/k1')!, 'hang');
      await _settle(5);
      system.kill(sup);
      expect(system.getActor('sup/k1'), isNull);
      expect(system.getActor('sup/k2'), isNull);
      expect(_log, ['start:k1', 'start:k2', 'stop:k2', 'stop:k1', 'stop:sup']);
    });

    test('overtakes a graceful stop that is still waiting', () async {
      final a = await system.spawn('a', () => _Probe('a'));
      _tell(a, 'hang');
      await _settle(5);
      final stopping = system.stop(a);
      system.kill(a);
      await stopping;
      expect(_log, ['start:a', 'stop:a']);
    });
  });

  group('nothing outlives its incarnation', () {
    test('timers and pending futures die with a stopped actor', () async {
      final a = await system.spawn('a', () => _Probe('a'));
      _tell(a, 'leave-work-behind');
      await _settle(12);
      await system.stop(a);
      final ticks = _log.where((l) => l == 'a:tick').length;
      expect(ticks, greaterThan(0));
      await _settle();
      expect(_log.where((l) => l == 'a:tick').length, ticks);
      expect(_log, isNot(contains('a:late')));
    });

    test('a restart cuts off what the old incarnation left behind', () async {
      final a =
          await system.spawn('a', () => _Probe('a'), supervision: _restart());
      _tell(a, 'leave-work-behind');
      _tell(a, 'boom');
      await _settle(15);
      final ticks = _log.where((l) => l == 'a:tick').length;
      await _settle();
      expect(a.isAlive, isTrue);
      expect(_log.where((l) => l == 'a:tick').length, ticks);
      expect(_log, isNot(contains('a:late')));
    });
  });

  test('a failed system call can be caught inside an actor', () async {
    final a = await system.spawn('a', () => _Probe('a'));
    _tell(a, 'spawn-twice');
    await _settle();
    expect(_log, contains('a:caught-duplicate'));
    expect(a.isAlive, isTrue);
  });
}
