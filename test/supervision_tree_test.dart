import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:test/test.dart';

final _log = <String>[];

class _Leaf extends Actor {
  final String name;
  _Leaf(this.name);

  @override
  FutureOr<void> preStart() {
    _log.add('start:$name');
  }

  @override
  Future<void> onMessage(dynamic message) async {
    if (message == 'boom') throw StateError('boom');
    _log.add('$name:$message');
  }

  @override
  void postStop() => _log.add('stop:$name');

  @override
  void onError(Object error, StackTrace stackTrace) => _log.add('error:$name');
}

class _Sup extends SupervisorActor {
  final String name;
  final List<String> kids;
  _Sup(this.name, SupervisionStrategy strategy, {this.kids = const []})
      : super(strategy);

  @override
  FutureOr<void> preStart() async {
    _log.add('start:$name');
    for (final kid in kids) {
      await supervise(kid, () => _Leaf(kid));
    }
  }

  @override
  void postStop() => _log.add('stop:$name');
}

SupervisionStrategy _always(SupervisionDecision d) =>
    OneForOneStrategy(decider: (e, s) => d);

Future<void> _settle([int ms = 60]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  late LocalActorSystem system;
  late InMemoryMetricsCollector metrics;

  setUp(() {
    _log.clear();
    metrics = InMemoryMetricsCollector();
    system = LocalActorSystem(ActorSystemConfig(
        metricsCollector: metrics, logCollector: const NoOpLogCollector()));
  });

  tearDown(() => system.shutdown());

  group('the supervision tree is a model', () {
    test('stopping a supervisor stops its subtree, last started first',
        () async {
      final top = await system.spawn(
          'top',
          () => _Sup('top', _always(SupervisionDecision.restart),
              kids: ['k1', 'k2', 'k3']));
      _log.clear();
      await system.stop(top);
      expect(_log, ['stop:k3', 'stop:k2', 'stop:k1', 'stop:top']);
      expect(system.getActor('top/k1'), isNull);
      expect(system.getActor('top/k2'), isNull);
    });

    test('a stopped pool takes its workers with it', () async {
      final pool =
          await system.spawn('p', () => _Leaf('w'), pool: Pool(workerCount: 3));
      expect(system.getActor('p/worker-0'), isNotNull);
      await system.stop(pool);
      expect(system.getActor('p/worker-0'), isNull);
      expect(system.getActor('p/worker-2'), isNull);
    });

    test('escalate hands the failure to the grandparent', () async {
      late _Sup grand;
      late _Sup mid;
      await system.spawn('grand', () {
        return grand = _Sup('grand', _always(SupervisionDecision.restart));
      });
      await grand.supervise('mid', () {
        return mid =
            _Sup('mid', _always(SupervisionDecision.escalate), kids: ['leaf']);
      });
      final first = mid;
      _log.clear();

      system.getActor('grand/mid/leaf')!.tell(LocalMessage(payload: 'boom'));
      await _settle();

      // The grandparent restarted mid; mid's children went down with the old
      // incarnation and its new preStart brought the leaf back.
      expect(_log, [
        'error:leaf',
        'stop:leaf',
        'stop:mid',
        'start:mid',
        'start:leaf',
      ]);
      expect(identical(mid, first), isFalse);
      expect(system.getActor('grand/mid/leaf')!.isAlive, isTrue);
      expect(metrics.getCounter('actors.escalated'), 1);
    });

    test('escalating past the top stops the top-level supervisor', () async {
      final top = await system.spawn(
          'top',
          () => _Sup('top', _always(SupervisionDecision.escalate),
              kids: ['leaf']));
      system.getActor('top/leaf')!.tell(LocalMessage(payload: 'boom'));
      await _settle();
      expect(top.isAlive, isFalse);
      expect(system.getActor('top/leaf'), isNull);
    });

    test('spawn(supervision:) governs a top-level actor', () async {
      final ref = await system.spawn('solo', () => _Leaf('solo'),
          supervision: _always(SupervisionDecision.restart));
      ref.tell(LocalMessage(payload: 'boom'));
      ref.tell(LocalMessage(payload: 'after'));
      await _settle();
      expect(ref.isAlive, isTrue);
      expect(_log, [
        'start:solo',
        'error:solo',
        'stop:solo',
        'start:solo',
        'solo:after'
      ]);
    });

    test('resume keeps a top-level actor and its state', () async {
      final ref = await system.spawn('solo', () => _Leaf('solo'),
          supervision: _always(SupervisionDecision.resume));
      ref.tell(LocalMessage(payload: 'boom'));
      ref.tell(LocalMessage(payload: 'after'));
      await _settle();
      expect(_log, ['start:solo', 'error:solo', 'solo:after']);
    });

    test('a top-level actor with no strategy is stopped on failure', () async {
      final ref = await system.spawn('solo', () => _Leaf('solo'));
      ref.tell(LocalMessage(payload: 'boom'));
      await _settle();
      expect(ref.isAlive, isFalse);
    });

    test('two children failing together are each restarted once', () async {
      await system.spawn(
          'top',
          () => _Sup('top',
              AllForOneStrategy(decider: (e, s) => SupervisionDecision.restart),
              kids: ['a', 'b']));
      _log.clear();
      system.getActor('top/a')!.tell(LocalMessage(payload: 'boom'));
      system.getActor('top/b')!.tell(LocalMessage(payload: 'boom'));
      await _settle();
      expect(_log.where((l) => l == 'start:a').length, 1);
      expect(_log.where((l) => l == 'start:b').length, 1);
      expect(metrics.getCounter('actors.restarted'), 2);
    });
  });
}
