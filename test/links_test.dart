import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:test/test.dart';

final _log = <String>[];
final _never = Completer<void>();

String _describe(ExitReason reason) => switch (reason) {
      NormalExit() => 'normal',
      ShutdownExit() => 'shutdown',
      KilledExit() => 'killed',
      NoProcExit() => 'noproc',
      NoConnectionExit() => 'noconnection',
      ErrorExit(:final error) => switch (error) {
          LinkedActorExited(:final from, :final reason) =>
            'linked(${from.id}, ${_describe(reason)})',
          _ => 'error($error)',
        },
    };

/// Watches whatever it is told to and logs how each one ended.
class _Watcher extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {
    switch (message) {
      case ActorRef target:
        context.watch(target);
      case Terminated(:final actor, :final reason):
        _log.add('${actor.id} terminated: ${_describe(reason)}');
    }
  }
}

class _Node extends Actor {
  final String name;
  final bool trap;
  final ActorRef? linkOnStart;
  _Node(this.name, {this.trap = false, this.linkOnStart});

  @override
  FutureOr<void> preStart() {
    _log.add('start:$name');
    context.trapExits = trap;
    final target = linkOnStart;
    if (target != null) context.link(target);
  }

  @override
  Future<void> onMessage(dynamic message) async {
    switch (message) {
      case ('link', ActorRef other):
        context.link(other);
      case ('unlink', ActorRef other):
        context.unlink(other);
      case ExitSignal(:final from, :final reason):
        _log.add('$name got exit from ${from.id}: ${_describe(reason)}');
      case 'boom':
        throw StateError('boom');
      case 'hang':
        await _never.future;
      default:
        _log.add('$name:$message');
    }
  }
}

class _Sup extends SupervisorActor {
  _Sup()
      : super(
            OneForOneStrategy(decider: (e, s) => SupervisionDecision.restart));

  @override
  FutureOr<void> preStart() async {
    await supervise('kid', () => _Node('kid'));
  }
}

SupervisionStrategy _restart() =>
    OneForOneStrategy(decider: (e, s) => SupervisionDecision.restart);

Future<void> _settle([int ms = 40]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void _tell(ActorRef ref, Object payload) =>
    ref.tell(LocalMessage(payload: payload));

void main() {
  late LocalActorSystem system;
  late ActorRef watcher;

  Future<ActorRef> node(String name,
      {bool trap = false, SupervisionStrategy? supervision}) async {
    final ref = await system.spawn(name, () => _Node(name, trap: trap),
        supervision: supervision);
    _tell(watcher, ref);
    return ref;
  }

  Future<void> build({Duration? stopTimeout}) async {
    system = LocalActorSystem(ActorSystemConfig(
        logCollector: const NoOpLogCollector(), stopTimeout: stopTimeout));
    watcher = await system.spawn('watcher', () => _Watcher());
  }

  setUp(() async {
    _log.clear();
    await build();
  });

  tearDown(() => system.shutdown());

  List<String> terminations() =>
      _log.where((l) => l.contains('terminated')).toList();

  group('Terminated says why', () {
    test('stop is normal, kill is killed, a failure carries the error',
        () async {
      final a = await node('a');
      final b = await node('b');
      final c = await node('c');
      await _settle(5);
      await system.stop(a);
      system.kill(b);
      _tell(c, 'boom');
      await _settle();
      expect(terminations(), [
        'a terminated: normal',
        'b terminated: killed',
        'c terminated: error(Bad state: boom)',
      ]);
    });

    test('children of a stopped parent end with shutdown', () async {
      final sup = await system.spawn('sup', () => _Sup());
      _tell(watcher, system.getActor('sup/kid')!);
      _tell(watcher, sup);
      await _settle(5);
      await system.stop(sup);
      await _settle();
      expect(terminations(),
          ['sup/kid terminated: shutdown', 'sup terminated: normal']);
    });

    test('an actor that outlasts the stop timeout ends as killed', () async {
      await system.shutdown();
      await build(stopTimeout: const Duration(milliseconds: 30));
      final a = await node('a');
      _tell(a, 'hang');
      await _settle(5);
      await system.stop(a);
      await _settle();
      expect(terminations(), ['a terminated: killed']);
    });
  });

  group('links', () {
    test('an abnormal exit brings down the linked actor', () async {
      final a = await node('a');
      final b = await node('b');
      _tell(a, ('link', b));
      await _settle(5);
      _tell(b, 'boom');
      await _settle();
      expect(a.isAlive, isFalse);
      expect(terminations(), [
        'b terminated: error(Bad state: boom)',
        'a terminated: error(Bad state: boom)',
      ]);
    });

    test('works in both directions', () async {
      final a = await node('a');
      final b = await node('b');
      _tell(a, ('link', b));
      await _settle(5);
      _tell(a, 'boom');
      await _settle();
      expect(b.isAlive, isFalse);
    });

    test('a normal exit leaves the linked actor alone', () async {
      final a = await node('a');
      final b = await node('b');
      _tell(a, ('link', b));
      await _settle(5);
      await system.stop(b);
      await _settle();
      expect(a.isAlive, isTrue);
    });

    test('a kill propagates as killed', () async {
      final a = await node('a');
      final b = await node('b');
      _tell(a, ('link', b));
      await _settle(5);
      system.kill(b);
      await _settle();
      expect(terminations(), ['b terminated: killed', 'a terminated: killed']);
    });

    test('unlink stops the propagation', () async {
      final a = await node('a');
      final b = await node('b');
      _tell(a, ('link', b));
      _tell(a, ('unlink', b));
      await _settle(5);
      _tell(b, 'boom');
      await _settle();
      expect(a.isAlive, isTrue);
    });

    test('linking to a dead actor signals noproc', () async {
      final dead = await node('dead');
      await system.stop(dead);
      final a = await node('a');
      final t = await node('t', trap: true);
      _tell(a, ('link', dead));
      _tell(t, ('link', dead));
      await _settle();
      expect(a.isAlive, isFalse);
      expect(t.isAlive, isTrue);
      expect(_log, contains('t got exit from dead: noproc'));
      expect(terminations().last, 'a terminated: noproc');
    });
  });

  group('trapExits', () {
    test('turns exits, normal ones too, into messages', () async {
      final t = await node('t', trap: true);
      final b = await node('b');
      final c = await node('c');
      _tell(t, ('link', b));
      _tell(t, ('link', c));
      await _settle(5);
      _tell(b, 'boom');
      await system.stop(c);
      await _settle();
      expect(t.isAlive, isTrue);
      expect(
          _log.where((l) => l.startsWith('t got')),
          unorderedEquals([
            't got exit from b: error(Bad state: boom)',
            't got exit from c: normal',
          ]));
    });
  });

  group('links and supervision', () {
    test('the linked actor fails, and its supervisor decides', () async {
      final a = await node('a', supervision: _restart());
      final b = await node('b');
      _tell(a, ('link', b));
      await _settle(5);
      _tell(b, 'boom');
      await _settle();
      _tell(a, 'hello');
      await _settle(10);
      // a was restarted rather than stopped, and still works.
      expect(a.isAlive, isTrue);
      expect(_log.where((l) => l == 'start:a').length, 2);
      expect(_log.last, 'a:hello');
    });

    test('a restart signals the links and dissolves them', () async {
      final t = await node('t', trap: true);
      final b = await node('b', supervision: _restart());
      _tell(t, ('link', b));
      await _settle(5);
      _tell(b, 'boom');
      await _settle();
      expect(b.isAlive, isTrue);
      expect(_log, contains('t got exit from b: error(Bad state: boom)'));

      _tell(b, 'boom');
      await _settle();
      expect(_log.where((l) => l.startsWith('t got')).length, 1);
    });

    test('two linked, restarting actors do not restart each other forever',
        () async {
      final a = await node('a', supervision: _restart());
      final b = await node('b', supervision: _restart());
      _tell(a, ('link', b));
      await _settle(5);
      _tell(a, 'boom');
      await _settle(80);
      expect(_log.where((l) => l == 'start:a').length, 2);
      expect(_log.where((l) => l == 'start:b').length, 2);
      expect(a.isAlive && b.isAlive, isTrue);
    });

    test('a link made in preStart is made again after a restart', () async {
      final t = await node('t', trap: true);
      final b = await system.spawn('b', () => _Node('b', linkOnStart: t),
          supervision: _restart());
      _tell(b, 'boom');
      await _settle();
      _tell(b, 'boom');
      await _settle();
      expect(_log.where((l) => l.startsWith('t got')).length, 2);
    });
  });
}
