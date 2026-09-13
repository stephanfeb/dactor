import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:dactor/src/metrics/metrics.dart';
import 'package:test/test.dart';

class _Plain extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {}
}

class _Thrower extends Actor {
  static final log = <String>[];
  @override
  Future<void> onMessage(dynamic message) async {
    if (message == 'boom') throw StateError('boom');
    log.add('$message');
  }
}

class _Counter extends Actor {
  static int starts = 0;
  @override
  FutureOr<void> preStart() => starts++;
  @override
  Future<void> onMessage(dynamic message) async {
    if (message == 'boom') throw StateError('boom');
  }
}

class _Sup extends SupervisorActor {
  _Sup(SupervisionStrategy strategy) : super(strategy);
}

/// A supervisor that implements the abstract [Supervisor] directly, without
/// going through [SupervisorActor].
class _BareSupervisor extends Supervisor {
  final failures = <String>[];

  @override
  SupervisionStrategy get strategy =>
      OneForOneStrategy(decider: (e, s) => SupervisionDecision.stop);

  @override
  Future<void> onMessage(dynamic message) async {}

  @override
  Future<ActorRef> supervise<T extends Actor>(
      String id, T Function() actorFactory) {
    return (context.system as LocalActorSystem)
        .spawnChild(context.self.id, id, actorFactory);
  }

  @override
  Future<SupervisionDecision> onChildFailure(
      ActorRef child, Object error, StackTrace stackTrace) async {
    failures.add(child.id);
    await context.system.stop(child);
    return SupervisionDecision.stop;
  }
}

Future<void> _settle([int ms = 60]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  late LocalActorSystem system;
  InMemoryMetricsCollector metrics() => system.metrics as InMemoryMetricsCollector;

  setUp(() {
    _Thrower.log.clear();
    _Counter.starts = 0;
    system = LocalActorSystem();
  });

  tearDown(() => system.shutdown());

  group('failure routing ignores the name', () {
    test('a slash-named actor under a non-supervisor does not crash the process',
        () async {
      await system.spawn('plain', () => _Plain());
      final evil = await system.spawn('plain/evil', () => _Thrower());

      evil.tell(LocalMessage(payload: 'boom'));
      await _settle();

      // Treated as unsupervised: stopped, nothing escaped.
      expect(evil.isAlive, isFalse);
      expect(system.getActor('plain/evil'), isNull);
      expect(system.getActor('plain')!.isAlive, isTrue);
      expect(metrics().getCounter('actors.failed'), 1);
      expect(metrics().getCounter('actors.supervision_failed'), 0);
    });

    test('an impostor cannot attach itself to a foreign supervisor', () async {
      final spawned = await system.spawnAndGetActor(
          'sup',
          () => _Sup(AllForOneStrategy(
              decider: (e, s) => SupervisionDecision.restart)));
      final sup = spawned.actor as _Sup;
      await sup.supervise('real1', () => _Counter());
      await sup.supervise('real2', () => _Counter());
      expect(_Counter.starts, 2);

      // Same naming shape as a real child, but spawned outside the supervisor.
      final impostor = await system.spawn('sup/impostor', () => _Thrower());
      impostor.tell(LocalMessage(payload: 'boom'));
      await _settle();

      expect(impostor.isAlive, isFalse, reason: 'unsupervised actors stop');
      expect(_Counter.starts, 2, reason: 'real children were not restarted');
      expect(system.getActor('sup/real1')!.isAlive, isTrue);
      expect(system.getActor('sup/real2')!.isAlive, isTrue);
    });

    test('a real child is still routed to its supervisor', () async {
      final spawned = await system.spawnAndGetActor(
          'sup',
          () => _Sup(OneForOneStrategy(
              decider: (e, s) => SupervisionDecision.restart)));
      final child =
          await (spawned.actor as _Sup).supervise('c', () => _Counter());
      child.tell(LocalMessage(payload: 'boom'));
      await _settle();

      expect(child.isAlive, isTrue);
      expect(_Counter.starts, 2);
    });

    test('a supervisor implementing Supervisor directly is honoured', () async {
      final spawned =
          await system.spawnAndGetActor('bare', () => _BareSupervisor());
      final bare = spawned.actor as _BareSupervisor;
      final child = await bare.supervise('c', () => _Thrower());

      child.tell(LocalMessage(payload: 'boom'));
      await _settle();

      expect(bare.failures, ['bare/c']);
      expect(child.isAlive, isFalse);
    });

    test('a child whose supervisor has been stopped is stopped on failure',
        () async {
      final spawned = await system.spawnAndGetActor(
          'sup',
          () => _Sup(OneForOneStrategy(
              decider: (e, s) => SupervisionDecision.restart)));
      final child =
          await (spawned.actor as _Sup).supervise('c', () => _Counter());
      await system.stop(spawned.ref);

      child.tell(LocalMessage(payload: 'boom'));
      await _settle();

      expect(child.isAlive, isFalse);
      expect(_Counter.starts, 1);
    });
  });

  group('child id validation', () {
    late _Sup sup;

    setUp(() async {
      final spawned = await system.spawnAndGetActor(
          'sup',
          () => _Sup(OneForOneStrategy(
              decider: (e, s) => SupervisionDecision.restart)));
      sup = spawned.actor as _Sup;
    });

    test('rejects ids containing a slash', () {
      expect(() => sup.supervise('a/b', () => _Plain()),
          throwsA(isA<ArgumentError>()));
    });

    test('rejects empty ids', () {
      expect(() => sup.supervise('', () => _Plain()),
          throwsA(isA<ArgumentError>()));
      expect(() => system.spawn('', () => _Plain()),
          throwsA(isA<ArgumentError>()));
    });

    test('rejects a parent that is not a supervisor', () async {
      await system.spawn('plain', () => _Plain());
      expect(() => system.spawnChild('plain', 'c', () => _Plain()),
          throwsA(isA<ArgumentError>()));
      expect(() => system.spawnChild('missing', 'c', () => _Plain()),
          throwsA(isA<ArgumentError>()));
    });
  });

  group('supervision errors are contained', () {
    test('a throwing onChildFailure stops the child and is recorded',
        () async {
      final spawned =
          await system.spawnAndGetActor('bad', () => _ThrowingSupervisor());
      final child = await (spawned.actor as _ThrowingSupervisor)
          .supervise('c', () => _Thrower());

      child.tell(LocalMessage(payload: 'boom'));
      await _settle();

      expect(child.isAlive, isFalse);
      expect(metrics().getCounter('actors.supervision_failed'), 1);
      expect(spawned.ref.isAlive, isTrue);
    });
  });
}

class _ThrowingSupervisor extends SupervisorActor {
  _ThrowingSupervisor()
      : super(OneForOneStrategy(decider: (e, s) => SupervisionDecision.restart));

  @override
  Future<SupervisionDecision> onChildFailure(
      ActorRef child, Object error, StackTrace stackTrace) {
    throw StateError('supervisor bug');
  }
}
