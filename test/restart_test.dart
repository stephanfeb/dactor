import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:test/test.dart';

/// Records everything that happens to it so tests can inspect lifecycle order.
class _Worker extends Actor {
  static final log = <String>[];
  static final received = <String>[];
  static int instances = 0;

  final int instance;
  final Duration preStartDelay;
  int handled = 0;

  _Worker({this.preStartDelay = Duration.zero}) : instance = ++instances;

  @override
  FutureOr<void> preStart() async {
    if (preStartDelay > Duration.zero) {
      await Future<void>.delayed(preStartDelay);
    }
    log.add('preStart#$instance');
  }

  @override
  Future<void> onMessage(dynamic message) async {
    if (message == 'boom') throw StateError('boom');
    handled++;
    received.add('$message@$instance');
    if (message is Map && message['replyTo'] is ActorRef) {
      (message['replyTo'] as ActorRef).tell(LocalMessage(payload: 'pong'));
    }
  }

  @override
  void postStop() => log.add('postStop#$instance');

  static void reset() {
    log.clear();
    received.clear();
    instances = 0;
  }
}

class _TickingWorker extends _Worker {
  static int ticks = 0;

  @override
  FutureOr<void> preStart() {
    // Only the first incarnation starts a timer, so any tick after a restart
    // can only come from a timer that should have been cancelled.
    if (instance == 1) {
      context.timers.startTimerAtFixedRate(
          'tick', 'tick', const Duration(milliseconds: 5));
    }
    return super.preStart();
  }

  @override
  Future<void> onMessage(dynamic message) async {
    if (message == 'tick') {
      ticks++;
      return;
    }
    return super.onMessage(message);
  }
}

class _Collector extends Actor {
  final messages = <dynamic>[];
  @override
  Future<void> onMessage(dynamic message) async => messages.add(message);
}

class _Event {}

class _Sup extends SupervisorActor {
  _Sup([SupervisionStrategy? strategy])
      : super(strategy ??
            OneForOneStrategy(
                decider: (e, s) => SupervisionDecision.restart));
}

Future<void> _settle([int ms = 60]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  late LocalActorSystem system;

  setUp(() {
    _Worker.reset();
    _TickingWorker.ticks = 0;
    system = LocalActorSystem(
        ActorSystemConfig(metricsCollector: InMemoryMetricsCollector()));
  });

  tearDown(() => system.shutdown());

  Future<({ActorRef child, _Sup sup})> supervised(
      {SupervisionStrategy? strategy,
      Actor Function()? factory,
      String name = 'child'}) async {
    final spawned =
        await system.spawnAndGetActor('sup', () => _Sup(strategy));
    final sup = spawned.actor as _Sup;
    final child = await sup.supervise(name, factory ?? () => _Worker());
    return (child: child, sup: sup);
  }

  group('restart keeps the ActorRef', () {
    test('same ref object, still alive, still registered', () async {
      final s = await supervised();
      s.child.tell(LocalMessage(payload: 'boom'));
      await _settle();

      expect(s.child.isAlive, isTrue);
      expect(identical(system.getActor('sup/child'), s.child), isTrue);
      expect(_Worker.log, ['preStart#1', 'postStop#1', 'preStart#2']);
    });

    test('messages through the old ref reach the new instance', () async {
      final s = await supervised();
      s.child.tell(LocalMessage(payload: 'boom'));
      await _settle();
      s.child.tell(LocalMessage(payload: 'after'));
      await _settle();

      expect(_Worker.received, ['after@2']);
      expect(system.deadLetterQueue.length, 0);
    });

    test('state is reset: the new instance starts fresh', () async {
      final s = await supervised();
      s.child.tell(LocalMessage(payload: 'a'));
      s.child.tell(LocalMessage(payload: 'b'));
      await _settle();
      s.child.tell(LocalMessage(payload: 'boom'));
      await _settle();
      s.child.tell(LocalMessage(payload: 'c'));
      await _settle();

      expect(_Worker.received, ['a@1', 'b@1', 'c@2']);
    });
  });

  group('restart keeps the mailbox', () {
    test('messages queued behind the failing one are delivered', () async {
      final s = await supervised();
      s.child.tell(LocalMessage(payload: 'a'));
      s.child.tell(LocalMessage(payload: 'boom'));
      s.child.tell(LocalMessage(payload: 'b'));
      s.child.tell(LocalMessage(payload: 'c'));
      await _settle(150);

      expect(_Worker.received, ['a@1', 'b@2', 'c@2']);
      expect(system.deadLetterQueue.length, 0);
    });

    test('nothing is delivered until the new preStart completes', () async {
      final s = await supervised(
          factory: () =>
              _Worker(preStartDelay: const Duration(milliseconds: 40)));
      await _settle();
      s.child.tell(LocalMessage(payload: 'boom'));
      await _settle(10);
      // Restart is in progress: preStart of instance 2 is still sleeping.
      s.child.tell(LocalMessage(payload: 'during'));
      await _settle(10);
      expect(_Worker.received, isEmpty);

      await _settle(150);
      expect(_Worker.log, ['preStart#1', 'postStop#1', 'preStart#2']);
      expect(_Worker.received, ['during@2']);
    });
  });

  group('restart keeps relationships', () {
    test('watchers are not sent Terminated', () async {
      final s = await supervised();
      final spawned =
          await system.spawnAndGetActor('watcher', () => _Collector());
      s.child.watch(spawned.ref);

      s.child.tell(LocalMessage(payload: 'boom'));
      await _settle();

      expect((spawned.actor as _Collector).messages, isEmpty);
    });

    test('event-bus subscriptions survive', () async {
      final s = await supervised();
      system.eventBus.subscribe<_Event>(s.child);

      s.child.tell(LocalMessage(payload: 'boom'));
      await _settle();
      expect(system.eventBus.subscriptions[_Event], contains(s.child));

      system.eventBus.publish<_Event>(_Event());
      await _settle();
      expect(_Worker.received.single, startsWith("Instance of '_Event'@2"));
    });

    test('supervisor still tracks the child under the same ref', () async {
      final s = await supervised();
      s.child.tell(LocalMessage(payload: 'boom'));
      await _settle();
      s.child.tell(LocalMessage(payload: 'boom'));
      await _settle();

      expect(_Worker.log, [
        'preStart#1',
        'postStop#1',
        'preStart#2',
        'postStop#2',
        'preStart#3',
      ]);
    });
  });

  group('restart resets timers', () {
    test('timers of the old instance stop firing', () async {
      final s = await supervised(factory: () => _TickingWorker());
      await _settle(30);
      expect(_TickingWorker.ticks, greaterThan(0));

      s.child.tell(LocalMessage(payload: 'boom'));
      await _settle(30);
      expect(_Worker.log, ['preStart#1', 'postStop#1', 'preStart#2']);

      final ticksAfterRestart = _TickingWorker.ticks;
      await _settle(40);
      expect(_TickingWorker.ticks, ticksAfterRestart,
          reason: 'the old incarnation\'s timer must be cancelled');
    });
  });

  group('AllForOne', () {
    test('restarts every child in place', () async {
      final strategy = AllForOneStrategy(
          decider: (e, s) => SupervisionDecision.restart);
      final spawned = await system.spawnAndGetActor('sup', () => _Sup(strategy));
      final sup = spawned.actor as _Sup;
      final c1 = await sup.supervise('c1', () => _Worker());
      final c2 = await sup.supervise('c2', () => _Worker());

      c1.tell(LocalMessage(payload: 'boom'));
      await _settle(100);

      expect(c1.isAlive, isTrue);
      expect(c2.isAlive, isTrue);
      expect(identical(system.getActor('sup/c1'), c1), isTrue);
      expect(identical(system.getActor('sup/c2'), c2), isTrue);
      expect(_Worker.log, containsAll(['postStop#1', 'postStop#2']));
      expect(_Worker.log.where((e) => e.startsWith('preStart')).length, 4);

      c1.tell(LocalMessage(payload: 'x'));
      c2.tell(LocalMessage(payload: 'y'));
      await _settle();
      expect(_Worker.received, unorderedEquals(['x@3', 'y@4']));
    });
  });

  group('pools', () {
    test('a worker failure does not lose a slot', () async {
      final pool = await system.spawn('pool', () => _Worker(),
          pool: Pool(workerCount: 2));
      pool.tell(LocalMessage(payload: 'boom'));
      await _settle();

      for (var i = 0; i < 10; i++) {
        pool.tell(LocalMessage(payload: 'm$i'));
      }
      await _settle(150);

      expect(_Worker.received.length, 10);
      expect(system.deadLetterQueue.length, 0);
    });
  });

  group('failed restart', () {
    test('a preStart that throws stops the actor', () async {
      var starts = 0;
      final spawned = await system.spawnAndGetActor('sup', () => _Sup());
      final sup = spawned.actor as _Sup;
      final child = await sup.supervise('child', () {
        starts++;
        return starts == 1 ? _Worker() : _BadStart();
      });

      child.tell(LocalMessage(payload: 'boom'));
      await _settle();

      expect(child.isAlive, isFalse);
      expect(system.getActor('sup/child'), isNull);
      expect(
          (system.metrics as InMemoryMetricsCollector)
              .getCounter('actors.supervision_failed'),
          1);
    });
  });
}

class _BadStart extends Actor {
  @override
  FutureOr<void> preStart() => throw StateError('cannot start');
  @override
  Future<void> onMessage(dynamic message) async {}
}
