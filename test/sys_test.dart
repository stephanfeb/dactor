import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:test/test.dart';

final _log = <String>[];

class Plain extends Actor {
  int seen = 0;
  final Completer<void>? gate;
  Plain([this.gate]);

  @override
  Future<void> onMessage(dynamic message) async {
    if (message == 'wait') await gate!.future;
    if (message == 'boom') throw StateError('boom');
    seen++;
    _log.add('plain $message');
  }
}

class Tally extends GenServer<int, Object> {
  @override
  int init() => 0;

  @override
  int handleCast(Object message, int state) => state + 1;
}

/// Version 2 keeps a list where version 1 kept a count.
class TallyV2 extends GenServer<List<String>, Object> {
  @override
  int get version => 2;

  @override
  List<String> init() => [];

  @override
  List<String> codeChange(int oldVersion, Object? oldState) {
    _log.add('codeChange from v$oldVersion with $oldState');
    return List.filled(oldState as int, 'old', growable: true);
  }

  @override
  List<String> handleCast(Object message, List<String> state) =>
      [...state, '$message'];
}

class Collecting implements LogCollector {
  final records = <LogRecord>[];
  @override
  void record(LogRecord record) => records.add(record);
}

void main() {
  late LocalActorSystem system;
  late Collecting logs;

  setUp(() {
    _log.clear();
    logs = Collecting();
    system = LocalActorSystem(ActorSystemConfig(logCollector: logs));
  });

  tearDown(() => system.shutdown());

  Future<void> settle([int ms = 10]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  group('getState', () {
    test('returns the actor itself for a plain actor', () async {
      final ref = await system.spawn('plain', () => Plain());
      ref.tell('a');
      await settle();
      final state = await system.sys.getState(ref);
      expect(state, isA<Plain>().having((p) => p.seen, 'seen', 1));
    });

    test('returns the state value of a behaviour', () async {
      final ref = await system.spawn('tally', () => Tally());
      ref.tell('a');
      ref.tell('b');
      await settle();
      expect(await system.sys.getState(ref), 2);
    });

    test('jumps the queue but not the handler in flight', () async {
      final gate = Completer<void>();
      final ref = await system.spawn('plain', () => Plain(gate));
      ref.tell('wait');
      ref.tell('later');
      await settle();
      final pending = system.sys.getState(ref);
      gate.complete();
      final state = await pending as Plain;
      // 'wait' had finished; 'later' had not started.
      expect(state.seen, 1);
    });

    test('fails for a dead actor and times out on a stuck one', () async {
      final gate = Completer<void>();
      await system.shutdown();
      system = LocalActorSystem(
          ActorSystemConfig(stopTimeout: const Duration(milliseconds: 20)));
      final ref = await system.spawn('plain', () => Plain(gate));
      ref.tell('wait');
      await settle();
      await expectLater(
          system.sys.getState(ref, timeout: const Duration(milliseconds: 20)),
          throwsA(isA<TimeoutException>()));
      await system.stop(ref);
      expect(() => system.sys.getState(ref), throwsStateError);
    });
  });

  group('replaceState', () {
    test('replaces a behaviour state', () async {
      final ref = await system.spawn('tally', () => Tally());
      expect(await system.sys.replaceState(ref, (s) => (s as int) + 40), 40);
      ref.tell('a');
      await settle();
      expect(await system.sys.getState(ref), 41);
    });

    test('is refused by a plain actor, and a bad update reaches the caller',
        () async {
      final plain = await system.spawn('plain', () => Plain());
      await expectLater(
          system.sys.replaceState(plain, (s) => s), throwsUnsupportedError);
      final tally = await system.spawn('tally', () => Tally());
      await expectLater(system.sys.replaceState(tally, (s) => 'not an int'),
          throwsA(isA<TypeError>()));
      expect(await system.sys.getState(tally), 0);
    });
  });

  test('suspend holds user messages and still answers sys requests', () async {
    final ref = await system.spawn('tally', () => Tally());
    system.sys.suspend(ref);
    ref.tell('a');
    ref.tell('b');
    await settle();
    expect(await system.sys.getState(ref), 0);
    final stats = system.sys.statistics(ref);
    expect(stats.suspended, isTrue);
    expect(stats.mailboxSize, 2);
    system.sys.resume(ref);
    await settle();
    expect(await system.sys.getState(ref), 2);
    expect(system.sys.statistics(ref).mailboxSize, 0);
  });

  test('statistics count messages and restarts', () async {
    final ref = await system.spawn('plain', () => Plain(),
        supervision:
            OneForOneStrategy(decider: (_, __) => SupervisionDecision.restart));
    ref.tell('a');
    ref.tell('boom');
    ref.tell('b');
    await settle(30);
    final stats = system.sys.statistics(ref);
    expect(stats.messagesProcessed, 3);
    expect(stats.restarts, 1);
    expect(stats.busy, isFalse);
  });

  test('trace logs received messages until switched off', () async {
    final ref = await system.spawn('plain', () => Plain());
    system.sys.trace(ref, true);
    ref.tell('one');
    await settle();
    system.sys.trace(ref, false);
    ref.tell('two');
    await settle();
    final traced =
        logs.records.where((r) => r.message.startsWith('received')).toList();
    expect(traced.map((r) => r.message), ['received one']);
    expect(traced.single.level, LogLevel.debug);
  });

  group('upgrade', () {
    test('hands the state to codeChange and keeps ref and mailbox', () async {
      final ref = await system.spawn('tally', () => Tally());
      ref.tell('a');
      ref.tell('b');
      await settle();
      system.sys.suspend(ref);
      ref.tell('queued');
      await system.sys.upgrade(ref, () => TallyV2());
      system.sys.resume(ref);
      await settle();
      expect(_log, ['codeChange from v1 with 2']);
      expect(await system.sys.getState(ref), ['old', 'old', 'queued']);
      expect(ref.isAlive, isTrue);
    });

    test('later restarts use the new code, from init', () async {
      final ref = await system.spawn('tally', () => Tally(),
          supervision: OneForOneStrategy(
              decider: (_, __) => SupervisionDecision.restart));
      await system.sys.upgrade(ref, () => TallyV2());
      await system.sys
          .replaceState(ref, (s) => throw StateError('x'))
          .catchError((Object _) => null);
      expect(await system.sys.getState(ref), isA<List<String>>());
    });

    test('from a plain actor starts the new code with init', () async {
      final ref = await system.spawn('a', () => Plain());
      await system.sys.upgrade(ref, () => TallyV2());
      expect(await system.sys.getState(ref), isEmpty);
      expect(_log, isEmpty);
    });
  });
}
