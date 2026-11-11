import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:test/test.dart';

final _log = <String>[];

class _PingPong extends Actor {
  ActorRef? peer;
  int remaining;
  final Completer<void> done;
  _PingPong(this.remaining, this.done);

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is ActorRef) {
      peer = message;
      return;
    }
    if (--remaining <= 0) {
      if (!done.isCompleted) done.complete();
      return;
    }
    peer!.tell(LocalMessage(payload: 'ball'));
  }
}

class _Spinner extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {
    final sw = Stopwatch()..start();
    while (sw.elapsedMilliseconds < 30) {}
  }
}

class _FailsToStart extends Actor {
  @override
  FutureOr<void> preStart() async {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    throw StateError('no start');
  }

  @override
  Future<void> onMessage(dynamic message) async => _log.add('msg:$message');

  @override
  void postStop() => _log.add('postStop');
}

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

class _BadStop extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {}

  @override
  void postStop() => throw StateError('bad postStop');
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

  group('H2: the pump yields to the event loop', () {
    test('a timer fires on time while a backlog drains', () async {
      final done = Completer<void>();
      final a = await system.spawn('a', () => _PingPong(150000, done));
      final b = await system.spawn('b', () => _PingPong(150000, done));
      a.tell(LocalMessage(payload: b));
      b.tell(LocalMessage(payload: a));

      final sw = Stopwatch()..start();
      int? firedAt;
      Timer(const Duration(milliseconds: 1), () {
        firedAt = sw.elapsedMilliseconds;
      });
      var ticks = 0;
      final periodic =
          Timer.periodic(const Duration(milliseconds: 5), (_) => ticks++);

      a.tell(LocalMessage(payload: 'ball'));
      await done.future;
      final drained = sw.elapsedMilliseconds;
      periodic.cancel();

      expect(firedAt, isNotNull, reason: 'timer never fired during the drain');
      expect(firedAt!, lessThan(50));
      // The drain must have been long enough for the test to mean something.
      if (drained > 50) {
        expect(ticks, greaterThan(drained ~/ 20));
      }
    });

    test('a handler that blocks is counted', () async {
      final spinner = await system.spawn('spinner', () => _Spinner());
      spinner.tell(LocalMessage(payload: 'go'));
      await _settle();
      expect(metrics.getCounter('actors.blocking_handler'), 1);
    });
  });

  group('H5: a failed preStart leaves nothing behind', () {
    test('spawn rejects, the id is free, postStop does not run', () async {
      await expectLater(
          system.spawn('x', () => _FailsToStart()), throwsStateError);
      expect(system.getActor('x'), isNull);
      expect(_log, isEmpty);

      final again = await system.spawn('x', () => _Leaf('x'));
      expect(again.isAlive, isTrue);
    });

    test('a ref obtained during the failed start is dead afterwards', () async {
      final pending = system.spawn('y', () => _FailsToStart());
      final early = system.getActor('y')!;
      early.tell(LocalMessage(payload: 'early'));
      await expectLater(pending, throwsStateError);
      expect(early.isAlive, isFalse);
      await _settle();
      expect(_log, isEmpty);
    });

    test('an actor stopped during preStart still gets postStop', () async {
      final slow = Completer<void>();
      final pending = system.spawn('z', () => _SlowStart(slow));
      await system.stop(system.getActor('z')!);
      expect(_log, isEmpty);
      slow.complete();
      final ref = await pending;
      expect(ref.isAlive, isFalse);
      expect(_log, ['postStop']);
    });
  });

  group('H4: the supervision tree is a model', () {
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

    test('a throwing postStop does not block stop or shutdown', () async {
      final bad = await system.spawn('bad', () => _BadStop());
      final good = await system.spawn('good', () => _Leaf('good'));
      await system.stop(bad);
      expect(bad.isAlive, isFalse);
      expect(system.getActor('bad'), isNull);
      await system.spawn('bad2', () => _BadStop());
      await system.shutdown();
      expect(good.isAlive, isFalse);
    });
  });
}

class _SlowStart extends Actor {
  final Completer<void> gate;
  _SlowStart(this.gate);

  @override
  FutureOr<void> preStart() => gate.future;

  @override
  Future<void> onMessage(dynamic message) async {}

  @override
  void postStop() => _log.add('postStop');
}
