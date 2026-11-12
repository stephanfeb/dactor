import 'dart:async';
import 'dart:math';

import 'package:dactor/dactor.dart';
import 'package:dactor/spi.dart';
import 'package:dactor/simulation.dart';
import 'package:test/test.dart';

void _tell(ActorRef ref, Object payload) => ref.tell(payload);

/// Records what it receives.
class Recorder extends Actor {
  final List<Object?> seen;
  Recorder(this.seen);

  @override
  Future<void> onMessage(dynamic message) async => seen.add(message);
}

/// On 'go', sends its name to the target.
class Announcer extends Actor {
  final String name;
  final ActorRef target;
  Announcer(this.name, this.target);

  @override
  Future<void> onMessage(dynamic message) async => _tell(target, name);
}

/// The racy test: it assumes "first" reaches the recorder before "second",
/// which holds on the real scheduler only because that one is first-in,
/// first-out across actors.
Future<void> racy(LocalActorSystem system) async {
  final seen = <Object?>[];
  final recorder = await system.spawn('recorder', () => Recorder(seen));
  final a = await system.spawn('a', () => Announcer('first', recorder));
  final b = await system.spawn('b', () => Announcer('second', recorder));
  _tell(a, 'go');
  _tell(b, 'go');
  await Future<void>.delayed(const Duration(milliseconds: 20));
  expect(seen, ['first', 'second']);
}

class Echo extends Actor {
  @override
  Future<void> onMessage(dynamic message) async =>
      context.sender?.tell(message);
}

/// Sends everything straight back, forever if the other side does too.
class Bouncer extends Actor {
  @override
  Future<void> onMessage(dynamic message) async =>
      context.sender?.tell(message);
}

class Ticker extends Actor {
  final List<Duration> ticks;
  final Simulation sim;
  Ticker(this.ticks, this.sim);

  @override
  void preStart() => context.timers
      .startTimerAtFixedRate('tick', 'tick', const Duration(seconds: 10));

  @override
  Future<void> onMessage(dynamic message) async => ticks.add(sim.elapsed);
}

class Worker extends Actor {
  final Map<String, int> counts;
  Worker(this.counts);

  @override
  void preStart() => counts['starts'] = (counts['starts'] ?? 0) + 1;

  @override
  Future<void> onMessage(dynamic message) async =>
      counts['handled'] = (counts['handled'] ?? 0) + 1;
}

class Pool extends SupervisorActor {
  final Map<String, int> counts;
  Pool(this.counts)
      : super(const OneForOneStrategy(decider: _restart, maxRestarts: 1000000));

  @override
  Future<void> preStart() async {
    for (var i = 0; i < 3; i++) {
      await supervise('w$i', () => Worker(counts));
    }
  }

  @override
  Future<void> onMessage(dynamic message) async {}
}

SupervisionDecision _restart(Object e, StackTrace s) =>
    SupervisionDecision.restart;

sealed class CounterMsg {}

final class Add extends CounterMsg {
  final int n;
  Add(this.n);
  @override
  String toString() => 'Add($n)';
}

final class Reset extends CounterMsg {
  @override
  String toString() => 'Reset';
}

final class Read extends CounterMsg with Call<int> {
  @override
  String toString() => 'Read';
}

class Counter extends GenServer<int, CounterMsg> {
  /// A deliberate bug: adding to a total of exactly this loses the update.
  final int? forgetsAt;
  Counter({this.forgetsAt});

  @override
  int init() => 0;

  @override
  int handleCast(CounterMsg message, int state) => switch (message) {
        Add(:final n) => state == forgetsAt ? state : state + n,
        Reset() => 0,
        Read() => state,
      };

  @override
  CallResult<int> handleCall(CounterMsg request, int state, From from) =>
      switch (request) {
        Read() => request.reply(state, state),
        _ => NoReply(state),
      };
}

void main() {
  group('the racy two-actor test', () {
    test('passes on the real scheduler', () async {
      final system = LocalActorSystem(
          ActorSystemConfig(logCollector: const NoOpLogCollector()));
      addTearDown(system.shutdown);
      for (var i = 0; i < 20; i++) {
        await racy(system);
        for (final id in ['recorder', 'a', 'b']) {
          await system.stop(system.getActor(id)!);
        }
      }
    });

    test('fails under some seed, and that seed fails the same way every time',
        () {
      SimulationFailure? found;
      try {
        explore((sim) => racy(sim.system), seeds: 50);
      } on SimulationFailure catch (failure) {
        found = failure;
      }
      expect(found, isNotNull, reason: 'no seed in 0..49 exposed the race');
      final failure = found!;
      expect(failure.error, isA<TestFailure>());
      expect(failure.toString(), contains('seed ${failure.seed}'));

      for (var i = 0; i < 25; i++) {
        late Simulation replay;
        expect(
            () => simulate((sim) {
                  replay = sim;
                  return racy(sim.system);
                }, seed: failure.seed),
            throwsA(isA<TestFailure>()));
        expect(replay.trace, failure.trace);
      }
    });

    test('some seeds pass, and they keep passing', () {
      final passing = [
        for (var seed = 0; seed < 50; seed++)
          if (_passes(seed)) seed
      ];
      expect(passing, isNotEmpty);
      expect(passing.length, lessThan(50));
      for (final seed in passing) {
        expect(_passes(seed), isTrue);
      }
    });
  });

  group('determinism', () {
    List<String> run(int seed) => simulate((sim) async {
          final seen = <Object?>[];
          final recorder = await sim.system.spawn('r', () => Recorder(seen));
          final senders = [
            for (var i = 0; i < 5; i++)
              await sim.system
                  .spawn('s$i', () => Announcer('from $i', recorder))
          ];
          for (final sender in senders) {
            _tell(sender, 'go');
            _tell(sender, 'go');
          }
          await sim.settle();
          expect(seen, hasLength(10));
          return [...sim.trace, '$seen'];
        }, seed: seed);

    test('one seed gives one run; different seeds give different runs', () {
      expect(run(7), run(7));
      final distinct = {for (var seed = 0; seed < 30; seed++) '${run(seed)}'};
      expect(distinct.length, greaterThan(15));
    });
  });

  group('virtual time', () {
    test('an hour of waiting costs nothing and timers fire on schedule', () {
      final real = Stopwatch()..start();
      final ticks = <Duration>[];
      final elapsed = simulate((sim) async {
        await sim.system.spawn('ticker', () => Ticker(ticks, sim));
        // One second past the last tick, so that it has been delivered.
        await sim.wait(const Duration(minutes: 30, seconds: 1));
        return sim.elapsed;
      }, maxTime: const Duration(hours: 2));
      expect(elapsed, const Duration(minutes: 30, seconds: 1));
      expect(ticks, hasLength(180));
      expect(ticks.first, const Duration(seconds: 10));
      expect(ticks.last, const Duration(minutes: 30));
      expect(real.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('ask works, and its timeout runs on the virtual clock', () {
      simulate((sim) async {
        final echo = await sim.system.spawn('echo', () => Echo());
        expect(await echo.ask<String>('hi'), 'hi');
        final silent = await sim.system.spawn('silent', () => Recorder([]));
        await expectLater(silent.ask<String>('hi', const Duration(minutes: 5)),
            throwsA(isA<TimeoutException>()));
        expect(sim.elapsed, const Duration(minutes: 5));
      });
    });

    test('settle waits for the actors without moving the clock', () {
      simulate((sim) async {
        final seen = <Object?>[];
        final recorder = await sim.system.spawn('r', () => Recorder(seen));
        final a = await sim.system.spawn('a', () => Announcer('x', recorder));
        _tell(a, 'go');
        expect(seen, isEmpty);
        await sim.settle();
        expect(seen, ['x']);
        expect(sim.elapsed, Duration.zero);
      });
    });
  });

  group('limits', () {
    test('waiting for something that cannot happen is a deadlock', () {
      expect(() => simulate((sim) => Completer<void>().future),
          throwsA(isA<SimulationDeadlock>()));
    });

    test('a run that never ends is cut off', () {
      expect(
          () => simulate((sim) async {
                final a = await sim.system.spawn('a', () => Bouncer());
                final b = await sim.system.spawn('b', () => Bouncer());
                sendAs(b, () => a.tell('x'));
                await Completer<void>().future;
              }, maxSteps: 500),
          throwsA(isA<SimulationLimitExceeded>()));
    });

    test('an error nobody awaited fails the run', () {
      expect(
          () => simulate((sim) async {
                unawaited(Future<void>.error(StateError('stray')));
                await sim.wait(const Duration(seconds: 1));
              }),
          throwsStateError);
    });

    test('the body may return a value, and may be synchronous', () {
      expect(simulate((sim) => 42), 42);
      expect(simulate((sim) async => sim.seed, seed: 9), 9);
    });
  });

  group('fault injection', () {
    test('a dropped request times out', () {
      simulate((sim) async {
        final echo = await sim.system.spawn('echo', () => Echo());
        await expectLater(
            echo.ask<String>('hi'), throwsA(isA<TimeoutException>()));
      }, faults: (delivery) => Fault.drop);
    });

    test('a delayed message arrives late and behind later ones', () {
      simulate((sim) async {
        final seen = <Object?>[];
        final recorder = await sim.system.spawn('r', () => Recorder(seen));
        _tell(recorder, 'slow');
        _tell(recorder, 'fast');
        await sim.settle();
        expect(seen, ['fast']);
        await sim.wait(const Duration(seconds: 2));
        expect(seen, ['fast', 'slow']);
      },
          faults: (delivery) =>
              delivery.payload == 'slow' && delivery.elapsed == Duration.zero
                  ? const Fault.delay(Duration(seconds: 1))
                  : Fault.none);
    });

    test('a crash goes through supervision and the message is lost', () {
      simulate((sim) async {
        final counts = <String, int>{};
        final worker = await sim.system.spawn('w', () => Worker(counts),
            supervision: const OneForOneStrategy(decider: _restart));
        _tell(worker, 'crash me');
        _tell(worker, 'fine');
        await sim.settle();
        expect(counts, {'starts': 2, 'handled': 1});
        expect(worker.isAlive, isTrue);
      },
          faults: (delivery) =>
              delivery.payload == 'crash me' ? Fault.crash : Fault.none);
    });

    test('supervised workers survive random crashes, drops and delays', () {
      var crashes = 0;
      var drops = 0;
      final policy = randomFaults(drop: 0.05, crash: 0.1, delay: 0.1);
      explore((sim) async {
        var crashed = 0;
        var dropped = 0;
        final counts = <String, int>{};
        final pool = await sim.system.spawn('pool', () => Pool(counts));
        for (var i = 0; i < 60; i++) {
          _tell(sim.system.getActor('pool/w${i % 3}')!, i);
          if (i % 7 == 0) await sim.settle();
        }
        await sim.wait(const Duration(seconds: 1));
        await sim.settle();

        for (final line in sim.trace) {
          if (line.contains(' crash ')) crashed++;
          if (line.contains(' drop ')) dropped++;
        }
        crashes += crashed;
        drops += dropped;
        expect(pool.isAlive, isTrue);
        for (var i = 0; i < 3; i++) {
          expect(sim.system.getActor('pool/w$i')?.isAlive, isTrue);
        }
        // Every message was handled, dropped, or lost in a crash; a restart
        // keeps the mailbox, so nothing else goes missing.
        expect((counts['handled'] ?? 0) + crashed + dropped, 60);
        expect(counts['starts'], 3 + crashed);
      }, seeds: 300, faults: policy);
      expect(crashes, greaterThan(300));
      expect(drops, greaterThan(100));
    });

    test('randomFaults rejects impossible probabilities', () {
      expect(() => randomFaults(drop: 0.7, crash: 0.7), throwsArgumentError);
    });
  });

  group('checkCommands', () {
    Future<TypedRef<CounterMsg>> counter(Simulation sim,
            {int? forgetsAt}) async =>
        (await sim.system.spawn('counter', () => Counter(forgetsAt: forgetsAt)))
            .typed();

    CounterMsg generate(Random random, int model) =>
        switch (random.nextInt(10)) {
          0 => Reset(),
          < 4 => Read(),
          _ => Add(1 + random.nextInt(5)),
        };

    Future<int> apply(Simulation sim, TypedRef<CounterMsg> ref, int model,
        CounterMsg command) async {
      switch (command) {
        case Add(:final n):
          ref.tell(command);
          return model + n;
        case Reset():
          ref.tell(command);
          return 0;
        case Read():
          expect(await ref.call(command), model);
          return model;
      }
    }

    test('a correct counter agrees with its model', () {
      checkCommands<TypedRef<CounterMsg>, int, CounterMsg>(
          setup: counter,
          model: () => 0,
          generate: generate,
          apply: apply,
          seeds: 200,
          commands: 40);
    });

    test('a buggy counter is caught, with the seed and the commands', () {
      SimulationFailure? found;
      try {
        checkCommands<TypedRef<CounterMsg>, int, CounterMsg>(
            setup: (sim) => counter(sim, forgetsAt: 7),
            model: () => 0,
            generate: generate,
            apply: apply,
            seeds: 200,
            commands: 40);
      } on SimulationFailure catch (failure) {
        found = failure;
      }
      expect(found, isNotNull);
      expect(found!.commands, isNotEmpty);
      expect(found.commands!.last, isA<Read>());
      expect(found.toString(), contains('Commands:'));
    });
  });
}

bool _passes(int seed) {
  try {
    simulate((sim) => racy(sim.system), seed: seed);
    return true;
  } on TestFailure {
    return false;
  }
}
