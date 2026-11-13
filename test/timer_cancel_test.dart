import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:test/test.dart';

final _log = <String>[];

const _short = Duration(milliseconds: 1);

/// Waits long enough, inside a handler, for a [_short] timer to fire and
/// its tick to be queued behind the handler.
Future<void> _letTickQueue() =>
    Future<void>.delayed(const Duration(milliseconds: 15));

class TimerUser extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {
    final timers = context.timers;
    switch (message) {
      case 'cancel':
        timers.startSingleTimer('k', 'tick', _short);
        await _letTickQueue();
        timers.cancel('k');
      case 'restart key':
        timers.startSingleTimer('k', 'old tick', _short);
        await _letTickQueue();
        timers.startSingleTimer('k', 'new tick', _short);
      case 'cancel all':
        timers.startSingleTimer('a', 'tick a', _short);
        timers.startSingleTimer('b', 'tick b', _short);
        await _letTickQueue();
        timers.cancelAll();
      case 'cancel repeating':
        timers.startTimerAtFixedRate('r', 'beat', _short);
        await _letTickQueue();
        timers.cancel('r');
      case 'receive':
        timers.startSingleTimer('stale', 'stale tick', _short);
        await _letTickQueue();
        timers.cancel('stale');
        timers.startSingleTimer('fresh', 'fresh tick', _short);
        final got = await context.receive<String>(
            where: (m) => m.endsWith('tick'),
            timeout: const Duration(seconds: 1));
        _log.add('received $got');
      case 'fail':
        timers.startSingleTimer('k', 'tick', _short);
        await _letTickQueue();
        throw StateError('boom');
      default:
        _log.add('$message');
    }
  }
}

void main() {
  late LocalActorSystem system;
  late ActorRef actor;

  setUp(() async {
    _log.clear();
    system = LocalActorSystem(
        ActorSystemConfig(logCollector: const NoOpLogCollector()));
    actor = await system.spawn('t', () => TimerUser(),
        supervision:
            OneForOneStrategy(decider: (_, __) => SupervisionDecision.restart));
  });

  tearDown(() => system.shutdown());

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 40));

  test('a tick already queued is dropped by cancel', () async {
    actor.tell('cancel');
    await settle();
    expect(_log, isEmpty);
  });

  test('restarting a key drops the old tick', () async {
    actor.tell('restart key');
    await settle();
    expect(_log, ['new tick']);
  });

  test('cancelAll drops every queued tick', () async {
    actor.tell('cancel all');
    await settle();
    expect(_log, isEmpty);
  });

  test('cancelling a repeating timer drops its queued beats', () async {
    actor.tell('cancel repeating');
    await settle();
    expect(_log, isEmpty);
  });

  test('receive skips a cancelled tick and gets the current one', () async {
    actor.tell('receive');
    await settle();
    expect(_log, ['received fresh tick']);
  });

  test('a restarted actor does not get its old incarnation\'s ticks', () async {
    actor.tell('fail');
    await settle();
    actor.tell('after');
    await settle();
    expect(_log, ['after']);
  });

  test('a tick that is still current arrives as the plain message', () async {
    final (:ref, :actor) =
        await system.spawnAndGetActor('plain', () => TimerUser());
    actor.context.timers.startSingleTimer('k', 'hello', _short);
    await settle();
    expect(ref.isAlive, isTrue);
    expect(_log, ['hello']);
  });
}
