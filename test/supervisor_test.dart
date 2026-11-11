import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:test/test.dart';

final _log = <String>[];
final _never = Completer<void>();

class _Kid extends Actor {
  final String name;
  _Kid(this.name);

  @override
  FutureOr<void> preStart() {
    _log.add('start:$name');
  }

  @override
  Future<void> onMessage(dynamic message) async {
    switch (message) {
      case 'boom':
        throw StateError('boom');
      case 'hang':
        await _never.future;
      default:
        _log.add('$name:$message');
    }
  }

  @override
  void postStop() => _log.add('stop:$name');
}

class _Sup extends SupervisorActor {
  final List<ChildSpec> specs;
  _Sup(SupervisionStrategy strategy, this.specs) : super(strategy);

  @override
  FutureOr<void> preStart() async {
    _log.add('start:sup');
    await startChildren(specs);
  }

  @override
  Future<void> onMessage(dynamic message) async {
    switch (message) {
      case 'slow':
        await Future<void>.delayed(const Duration(milliseconds: 30));
        _log.add('sup:slow-done');
      case ('terminate', String name):
        await terminateChild(name);
      default:
        _log.add('sup:$message');
    }
  }

  @override
  Future<SupervisionDecision> onChildFailure(
      ActorRef child, Object error, StackTrace stackTrace) {
    _log.add('sup:deciding');
    return super.onChildFailure(child, error, stackTrace);
  }
}

class _Watcher extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {
    switch (message) {
      case ActorRef target:
        context.watch(target);
      case Terminated(:final actor, :final reason):
        final why = switch (reason) {
          ErrorExit(error: RestartLimitExceeded()) => 'restart limit',
          ErrorExit() => 'error',
          _ => '$reason',
        };
        _log.add('${actor.id} terminated: $why');
    }
  }
}

ChildSpec _kid(String name,
        {RestartType restart = RestartType.permanent, Duration? shutdown}) =>
    ChildSpec(name, () => _Kid(name), restart: restart, shutdown: shutdown);

SupervisionDecision _alwaysRestart(Object e, StackTrace s) =>
    SupervisionDecision.restart;

SupervisionDecision _alwaysEscalate(Object e, StackTrace s) =>
    SupervisionDecision.escalate;

Future<void> _settle([int ms = 40]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void _tell(ActorRef ref, Object payload) =>
    ref.tell(LocalMessage(payload: payload));

int _count(String entry) => _log.where((l) => l == entry).length;

void main() {
  late LocalActorSystem system;
  late InMemoryMetricsCollector metrics;
  late ActorRef watcher;

  setUp(() async {
    _log.clear();
    metrics = InMemoryMetricsCollector();
    system = LocalActorSystem(ActorSystemConfig(
        metricsCollector: metrics, logCollector: const NoOpLogCollector()));
    watcher = await system.spawn('watcher', () => _Watcher());
  });

  tearDown(() => system.shutdown());

  ActorRef kid(String name) => system.getActor('sup/$name')!;

  Future<ActorRef> sup(SupervisionStrategy strategy, List<ChildSpec> specs,
      {SupervisionStrategy? supervision}) async {
    final ref = await system.spawn('sup', () => _Sup(strategy, specs),
        supervision: supervision);
    _tell(watcher, ref);
    return ref;
  }

  group('restart budget', () {
    test('a supervisor that restarts too often gives up and fails', () async {
      final s = await sup(
          const OneForOneStrategy(decider: _alwaysRestart, maxRestarts: 2),
          [_kid('a'), _kid('b')]);
      // The budget is shared by all children: two for a, then one for b.
      _tell(kid('a'), 'boom');
      await _settle(10);
      _tell(kid('a'), 'boom');
      await _settle(10);
      expect(s.isAlive, isTrue);
      expect(_count('start:a'), 3);

      _tell(kid('b'), 'boom');
      await _settle();
      expect(s.isAlive, isFalse);
      expect(system.getActor('sup/a'), isNull);
      expect(system.getActor('sup/b'), isNull);
      expect(_log, contains('sup terminated: restart limit'));
    });

    test('only restarts inside the period count', () async {
      final s = await sup(
          const OneForOneStrategy(
              decider: _alwaysRestart,
              maxRestarts: 1,
              period: Duration(milliseconds: 30)),
          [_kid('a')]);
      for (var i = 0; i < 3; i++) {
        _tell(kid('a'), 'boom');
        await _settle(50);
      }
      expect(s.isAlive, isTrue);
      expect(_count('start:a'), 4);
    });

    test('giving up is a failure the next supervisor up can handle', () async {
      final s = await sup(
          const OneForOneStrategy(decider: _alwaysRestart, maxRestarts: 1),
          [_kid('a')],
          supervision: const OneForOneStrategy(decider: _alwaysRestart));
      _tell(kid('a'), 'boom');
      await _settle(10);
      _tell(kid('a'), 'boom');
      await _settle();
      // The supervisor itself was restarted, and brought its child back.
      expect(s.isAlive, isTrue);
      expect(_count('start:sup'), 2);
      expect(kid('a').isAlive, isTrue);
    });

    test('one strategy shared by two supervisors keeps two budgets', () async {
      const strategy =
          OneForOneStrategy(decider: _alwaysRestart, maxRestarts: 1);
      final one = await system.spawn('one', () => _Sup(strategy, [_kid('a')]));
      final two = await system.spawn('two', () => _Sup(strategy, [_kid('a')]));
      _tell(system.getActor('one/a')!, 'boom');
      _tell(system.getActor('two/a')!, 'boom');
      await _settle();
      expect(one.isAlive && two.isAlive, isTrue);
    });

    test('a top-level actor with a strategy has a budget of its own', () async {
      final a = await system.spawn('a', () => _Kid('a'),
          supervision:
              const OneForOneStrategy(decider: _alwaysRestart, maxRestarts: 2));
      _tell(watcher, a);
      for (var i = 0; i < 3; i++) {
        _tell(a, 'boom');
        await _settle(10);
      }
      expect(a.isAlive, isFalse);
      expect(_count('start:a'), 3);
      expect(_log, contains('a terminated: restart limit'));
      expect(metrics.getCounter('actors.restart_limit_exceeded'), 1);
    });
  });

  group('child specs', () {
    test('a temporary child that fails is stopped and forgotten', () async {
      await sup(const OneForOneStrategy(decider: _alwaysRestart),
          [_kid('t', restart: RestartType.temporary)]);
      _tell(kid('t'), 'boom');
      await _settle();
      expect(system.getActor('sup/t'), isNull);
      expect(_count('start:t'), 1);
    });

    test('a permanent child that is stopped is started again', () async {
      await sup(const OneForOneStrategy(decider: _alwaysRestart), [_kid('p')]);
      final first = kid('p');
      await system.stop(first);
      await _settle();
      final second = system.getActor('sup/p');
      expect(first.isAlive, isFalse);
      expect(second, isNotNull);
      expect(second!.isAlive, isTrue);
      expect(_count('start:p'), 2);
    });

    test('a transient child comes back after a kill, not after a stop',
        () async {
      await sup(const OneForOneStrategy(decider: _alwaysRestart),
          [_kid('t', restart: RestartType.transient)]);
      system.kill(kid('t'));
      await _settle();
      expect(system.getActor('sup/t'), isNotNull);
      expect(_count('start:t'), 2);

      await system.stop(kid('t'));
      await _settle();
      expect(system.getActor('sup/t'), isNull);
      expect(_count('start:t'), 2);
    });

    test('terminateChild stops a permanent child for good', () async {
      final s = await sup(
          const OneForOneStrategy(decider: _alwaysRestart), [_kid('p')]);
      _tell(watcher, kid('p'));
      await _settle(5);
      _tell(s, ('terminate', 'p'));
      await _settle();
      expect(system.getActor('sup/p'), isNull);
      expect(_count('start:p'), 1);
      expect(_log, contains('sup/p terminated: shutdown'));
    });

    test('a child with shutdown zero is not waited for', () async {
      final s = await sup(const OneForOneStrategy(decider: _alwaysRestart),
          [_kid('h', shutdown: Duration.zero)]);
      _tell(kid('h'), 'hang');
      await _settle(5);
      final sw = Stopwatch()..start();
      await system.stop(s);
      expect(sw.elapsedMilliseconds, lessThan(500));
      expect(_log, contains('stop:h'));
    });

    test('children restarted with their supervisor come from its preStart',
        () async {
      final s = await sup(const OneForOneStrategy(decider: _alwaysEscalate),
          [_kid('a'), _kid('b')],
          supervision: const OneForOneStrategy(decider: _alwaysRestart));
      _tell(kid('a'), 'boom');
      await _settle();
      expect(s.isAlive, isTrue);
      expect(_count('start:a'), 2);
      expect(_count('start:b'), 2);
    });
  });

  group('rest for one', () {
    test('restarts the failed child and those started after it', () async {
      await sup(const RestForOneStrategy(decider: _alwaysRestart),
          [_kid('a'), _kid('b'), _kid('c')]);
      _log.clear();
      _tell(kid('b'), 'boom');
      await _settle();
      expect(_log.where((l) => l.startsWith('start:')), ['start:b', 'start:c']);
      expect(_count('stop:a'), 0);
    });
  });

  group('supervision runs in the supervisor\'s mailbox', () {
    test('a decision never overlaps the supervisor\'s own handler', () async {
      final s = await sup(
          const OneForOneStrategy(decider: _alwaysRestart), [_kid('a')]);
      _log.clear();
      _tell(s, 'slow');
      await _settle(5);
      _tell(kid('a'), 'boom');
      await _settle(80);
      expect(_log, ['sup:slow-done', 'sup:deciding', 'stop:a', 'start:a']);
    });

    test('a decision goes ahead of the supervisor\'s backlog', () async {
      final s = await sup(
          const OneForOneStrategy(decider: _alwaysRestart), [_kid('a')]);
      _log.clear();
      _tell(s, 'slow');
      _tell(s, 'one');
      _tell(s, 'two');
      await _settle(5);
      _tell(kid('a'), 'boom');
      await _settle(80);
      expect(_log.take(3), ['sup:slow-done', 'sup:deciding', 'stop:a']);
      expect(_log.indexOf('sup:deciding'), lessThan(_log.indexOf('sup:one')));
    });

    test('a failed child receives nothing until the decision is made',
        () async {
      final s = await sup(
          const OneForOneStrategy(decider: _alwaysRestart), [_kid('a')]);
      _log.clear();
      _tell(s, 'slow');
      await _settle(5);
      _tell(kid('a'), 'boom');
      _tell(kid('a'), 'after');
      await _settle(10);
      expect(_log, isNot(contains('a:after')));
      await _settle(80);
      expect(_log.last, 'a:after');
    });
  });
}
