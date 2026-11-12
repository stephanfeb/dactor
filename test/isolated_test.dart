import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:dactor/dactor.dart';
import 'package:dactor/spi.dart';
import 'package:test/test.dart';

// Everything an actor in another isolate does must be observed through
// messages: it cannot touch this isolate's variables.

sealed class CounterMsg {}

final class Add extends CounterMsg {
  final int n;
  Add(this.n);
}

final class Get extends CounterMsg with Call<int> {}

final class Fail extends CounterMsg {}

final class FailCall extends CounterMsg with Call<int> {}

final class Quit extends CounterMsg with Call<String> {}

class Counter extends GenServer<int, CounterMsg> {
  @override
  int init() => 0;

  @override
  int handleCast(CounterMsg message, int state) => switch (message) {
        Add(:final n) => state + n,
        Fail() => throw StateError('told to fail'),
        _ => state,
      };

  @override
  CallResult<int> handleCall(CounterMsg request, int state, From from) =>
      switch (request) {
        Get() => request.reply(state, state),
        FailCall() => throw StateError('call failed'),
        Quit() => StopReply('bye', state),
        _ => NoReply(state),
      };
}

/// A plain actor that exercises the context from wherever it runs.
class Probe extends Actor {
  ActorRef? observer;
  int ticks = 0;

  @override
  Future<void> onMessage(dynamic message) async {
    switch (message) {
      case 'observe':
        observer = context.sender;
        context.sender?.tell('observing');
      case 'echo-later':
        final sender = context.sender;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        sender?.tell('later');
      case 'start-timer':
        context.timers
            .startSingleTimer('t', 'tick', const Duration(milliseconds: 10));
      case 'tick':
        ticks++;
        observer?.tell('ticked $ticks');
      case 'self':
        context.self.tell('tick');
      case 'spawn-child':
        final child = await context.spawn('inner-child', () => Counter());
        child.tell(Add(5));
        final value = await child.ask<int>(Get());
        context.sender?.tell(value);
      case 'ask-observer':
        final answer = await observer!.ask<String>('question');
        context.sender?.tell('observer said $answer');
      case 'boom':
        throw StateError('boom');
      case 'stray':
        unawaited(Future<void>.error(StateError('stray')));
      case 'spin':
        while (true) {}
      case 'isolate-name':
        context.sender?.tell(_isolateName());
    }
  }

  @override
  void postStop() => observer?.tell('stopped after $ticks ticks');
}

String _isolateName() => Isolate.current.debugName ?? '';

/// Collects what it is told, and answers questions.
class Observer extends Actor {
  final List<Object?> seen;
  Observer(this.seen);

  @override
  Future<void> onMessage(dynamic message) async {
    if (message == 'question') {
      context.sender?.tell('answer');
    } else {
      seen.add(message);
    }
  }
}

SupervisionDecision _restart(Object e, StackTrace s) =>
    SupervisionDecision.restart;
SupervisionDecision _resume(Object e, StackTrace s) =>
    SupervisionDecision.resume;

typedef Place = Actor Function(Actor Function() factory);

void main() {
  late LocalActorSystem system;
  late InMemoryMetricsCollector metrics;
  final logs = <LogRecord>[];

  setUp(() {
    logs.clear();
    metrics = InMemoryMetricsCollector();
    system = LocalActorSystem(ActorSystemConfig(
        metricsCollector: metrics, logCollector: _Logs(logs)));
  });

  tearDown(() => system.shutdown());

  Future<void> settle([int ms = 60]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  // The same behaviour, whichever side of an isolate boundary the actor
  // is on.
  final placements = <String, Place>{
    'shared': (factory) => factory(),
    'isolated': (factory) => Isolated(factory),
  };

  for (final MapEntry(key: name, value: place) in placements.entries) {
    group('placed $name:', () {
      Future<TypedRef<CounterMsg>> counter(
              {SupervisionStrategy? supervision}) async =>
          (await system.spawn('counter', () => place(Counter.new),
                  supervision: supervision))
              .typed();

      Future<(ActorRef, List<Object?>)> probe(
          {SupervisionStrategy? supervision}) async {
        final seen = <Object?>[];
        final observer = await system.spawn('observer', () => Observer(seen));
        final ref = await system.spawn('probe', () => place(Probe.new),
            supervision: supervision);
        await ref.ask<String>('observe').then((_) {});
        // Asked through a temporary ref; register the real observer too.
        sendAs(observer, () => ref.tell('observe'));
        await settle();
        seen.clear();
        return (ref, seen);
      }

      test('tell and call', () async {
        final ref = await counter();
        ref.tell(Add(2));
        ref.tell(Add(3));
        expect(await ref.call(Get()), 5);
      });

      test('messages are handled in the order sent', () async {
        final ref = await counter();
        for (var i = 1; i <= 200; i++) {
          ref.tell(Add(i));
        }
        expect(await ref.call(Get()), 20100);
      });

      test('a reply sent after an await still arrives', () async {
        final (ref, _) = await probe();
        expect(await ref.ask<String>('echo-later'), 'later');
      });

      test('timers and self-sends work inside', () async {
        final (ref, seen) = await probe();
        ref.tell('start-timer');
        ref.tell('self');
        await settle(120);
        expect(seen, unorderedEquals(['ticked 1', 'ticked 2']));
      });

      test('it can spawn and use actors of its own', () async {
        final (ref, _) = await probe();
        expect(await ref.ask<int>('spawn-child'), 5);
      });

      test('it can ask the actor that sent it a message', () async {
        final (ref, _) = await probe();
        expect(await ref.ask<String>('ask-observer'), 'observer said answer');
      });

      test('a failure with restart starts over with fresh state', () async {
        final ref = await counter(
            supervision: const OneForOneStrategy(decider: _restart));
        ref.tell(Add(9));
        ref.tell(Fail());
        await settle(150);
        expect(await ref.call(Get()), 0);
        expect(metrics.getCounter('actors.restarted'), 1);
      });

      test('a failure with resume keeps the state', () async {
        final ref = await counter(
            supervision: const OneForOneStrategy(decider: _resume));
        ref.tell(Add(9));
        ref.tell(Fail());
        ref.tell(Add(1));
        expect(await ref.call(Get()), 10);
      });

      test('a failing call reaches the caller as CallException', () async {
        final ref = await counter(
            supervision: const OneForOneStrategy(decider: _resume));
        await expectLater(ref.call(FailCall()), throwsA(isA<CallException>()));
        expect(await ref.call(Get()), 0);
      });

      test('an unsupervised failure stops it', () async {
        final ref = await counter();
        ref.tell(Fail());
        await settle(150);
        expect(ref.isAlive, isFalse);
      });

      test('an error nobody awaited is a failure too', () async {
        final (ref, _) = await probe(
            supervision: const OneForOneStrategy(decider: _restart));
        ref.tell('stray');
        await settle(150);
        expect(ref.isAlive, isTrue);
        expect(metrics.getCounter('actors.restarted'), 1);
      });

      test('stop runs postStop', () async {
        final (ref, seen) = await probe();
        ref.tell('self');
        await settle();
        await system.stop(ref);
        await settle(150);
        expect(ref.isAlive, isFalse);
        expect(seen, ['ticked 1', 'stopped after 1 ticks']);
      });

      test('an actor that stops itself is stopped here too', () async {
        final ref = await counter();
        final watcherSaw = <Object?>[];
        final watcher =
            await system.spawn('watcher', () => Observer(watcherSaw));
        ref.untyped.watch(watcher);
        expect(await ref.call(Quit()), 'bye');
        await settle(150);
        expect(ref.isAlive, isFalse);
        expect(watcherSaw.single, isA<Terminated>());
      });

      test('a pool of them shares the work', () async {
        final pool = await system.spawn('pool', () => place(Counter.new),
            pool: Pool(workerCount: 3));
        for (var i = 0; i < 6; i++) {
          pool.tell(Add(1));
        }
        await settle();
        final totals = [for (var i = 0; i < 3; i++) await pool.ask<int>(Get())];
        expect(totals, [2, 2, 2]);
      });
    });
  }

  group('only an isolate can:', () {
    test('be killed in an infinite loop and restarted, leaving others alone',
        () async {
      final bystander = (await system.spawn('bystander', () => Counter()))
          .typed<CounterMsg>();
      final other = (await system.spawn('other', () => Isolated(Counter.new)))
          .typed<CounterMsg>();
      final stuck = await system.spawn(
          'stuck',
          () => Isolated(Probe.new,
              heartbeat: const Duration(milliseconds: 20),
              unresponsiveAfter: const Duration(milliseconds: 150)),
          supervision: const OneForOneStrategy(decider: _restart));

      stuck.tell('spin');
      // While it spins, everyone else keeps working.
      for (var i = 0; i < 20; i++) {
        bystander.tell(Add(1));
        other.tell(Add(1));
        await settle(10);
      }
      expect(await bystander.call(Get()), 20);
      expect(await other.call(Get()), 20);

      await settle(300);
      expect(metrics.getCounter('actors.restarted'), 1);
      expect(stuck.isAlive, isTrue);
      // The replacement answers.
      expect(await stuck.ask<String>('echo-later'), 'later');
    });

    test('an unsupervised stuck actor is killed and stopped', () async {
      final watcherSaw = <Object?>[];
      final watcher = await system.spawn('watcher', () => Observer(watcherSaw));
      final stuck = await system.spawn(
          'stuck',
          () => Isolated(Probe.new,
              heartbeat: const Duration(milliseconds: 20),
              unresponsiveAfter: const Duration(milliseconds: 100)));
      stuck.watch(watcher);
      stuck.tell('spin');
      await settle(400);
      expect(stuck.isAlive, isFalse);
      expect(
          watcherSaw.single,
          isA<Terminated>().having(
              (t) => t.reason,
              'reason',
              isA<ErrorExit>().having(
                  (e) => e.error, 'error', isA<IsolateUnresponsive>())));
    });

    test('run in a different isolate', () async {
      final here = await system.spawn('here', () => Probe());
      final there = await system.spawn('there', () => Isolated(Probe.new));
      final a = await here.ask<String>('isolate-name');
      final b = await there.ask<String>('isolate-name');
      expect(b, 'dactor:there');
      expect(a, isNot(b));
    });
  });

  group('the boundary:', () {
    test('a message that cannot be sent goes to the dead letters', () async {
      final ref = (await system.spawn('counter', () => Isolated(Counter.new)))
          .typed<CounterMsg>();
      // An ActorRef of this system does not cross.
      ref.untyped.tell(ref.untyped);
      ref.tell(Add(1));
      expect(await ref.call(Get()), 1);
      expect(system.deadLetterQueue.length, 1);
      expect(logs.map((l) => l.message).join(), contains('cannot be sent'));
    });

    test('a factory that cannot be sent fails the spawn with advice', () async {
      final port = Completer<void>();
      await expectLater(
          system.spawn(
              'bad',
              () => Isolated(() {
                    // Captures this isolate's system: unsendable.
                    system.hashCode;
                    port.hashCode;
                    return Counter();
                  })),
          throwsA(isA<ArgumentError>().having(
              (e) => '$e', 'message', contains('constructor tear-off'))));
    });

    test('a failing preStart inside the isolate fails the spawn', () async {
      await expectLater(system.spawn('bad', () => Isolated(FailsToStart.new)),
          throwsA(isA<StateError>()));
    });

    test('a program that used isolates, and had one killed, still exits',
        () async {
      // An open port keeps a Dart program alive, and the test runner would
      // hide that, so run a real program and wait for it to end.
      final result = await Process.run(Platform.resolvedExecutable, [
        'run',
        'example/isolated_example.dart'
      ]).timeout(const Duration(seconds: 60));
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(result.stdout, contains('IsolateUnresponsive'));
      expect(result.stdout, contains('1000033 prime? true'));
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('shutting the system down ends its isolates promptly', () async {
      final own = LocalActorSystem(
          ActorSystemConfig(logCollector: const NoOpLogCollector()));
      for (var i = 0; i < 5; i++) {
        await own.spawn('c$i', () => Isolated(Counter.new));
      }
      final watch = Stopwatch()..start();
      await own.shutdown();
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    });
  });
}

class FailsToStart extends Actor {
  @override
  void preStart() => throw StateError('cannot start');

  @override
  Future<void> onMessage(dynamic message) async {}
}

class _Logs implements LogCollector {
  final List<LogRecord> records;
  _Logs(this.records);
  @override
  void record(LogRecord record) => records.add(record);
}
