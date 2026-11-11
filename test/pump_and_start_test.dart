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

class _Plain extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {}
}

class _BadStop extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {}

  @override
  void postStop() => throw StateError('bad postStop');
}

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

  group('the pump yields to the event loop', () {
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

  group('a failed preStart leaves nothing behind', () {
    test('spawn rejects, the id is free, postStop does not run', () async {
      await expectLater(
          system.spawn('x', () => _FailsToStart()), throwsStateError);
      expect(system.getActor('x'), isNull);
      expect(_log, isEmpty);

      final again = await system.spawn('x', () => _Plain());
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

    test('a stop during preStart waits for it, then runs postStop', () async {
      final slow = Completer<void>();
      final pending = system.spawn('z', () => _SlowStart(slow));
      final stopping = system.stop(system.getActor('z')!);
      await _settle(20);
      expect(_log, isEmpty);
      slow.complete();
      await stopping;
      final ref = await pending;
      expect(ref.isAlive, isFalse);
      expect(_log, ['postStop']);
    });
  });

  test('a throwing postStop does not block stop or shutdown', () async {
    final bad = await system.spawn('bad', () => _BadStop());
    final good = await system.spawn('good', () => _Plain());
    await system.stop(bad);
    expect(bad.isAlive, isFalse);
    expect(system.getActor('bad'), isNull);
    await system.spawn('bad2', () => _BadStop());
    await system.shutdown();
    expect(good.isAlive, isFalse);
  });
}
