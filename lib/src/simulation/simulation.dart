import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:dactor/src/actor_ref.dart';
import 'package:dactor/src/actor_system.dart';
import 'package:dactor/src/clock.dart';
import 'package:dactor/src/local_actor_system.dart';
import 'package:dactor/src/local_message.dart';
import 'package:dactor/src/logging/logging.dart';

/// A message a simulated system is about to hand to an actor.
class Delivery {
  /// The actor about to receive it.
  final ActorRef target;

  /// What its `onMessage` would be called with.
  final Object? payload;

  final ActorRef? sender;

  /// The simulation's random source. Decisions drawn from it are repeated
  /// when the seed is replayed; decisions drawn from anywhere else are not.
  final Random random;

  /// Virtual time since the simulation started.
  final Duration elapsed;

  Delivery._(this.target, this.payload, this.sender, this.random, this.elapsed);
}

/// What a [FaultPolicy] does with a [Delivery].
sealed class Fault {
  const Fault();

  /// Deliver the message.
  static const Fault none = _Simple('none');

  /// Lose the message.
  static const Fault drop = _Simple('drop');

  /// Lose the message and fail the actor with an [InjectedFault], as if its
  /// handler had thrown. Its supervisor decides what happens next.
  static const Fault crash = _Simple('crash');

  /// Deliver the message [after] this much virtual time, behind whatever
  /// has reached the mailbox by then.
  const factory Fault.delay(Duration after) = _Delay;
}

final class _Simple extends Fault {
  final String name;
  const _Simple(this.name);
}

final class _Delay extends Fault {
  final Duration after;
  const _Delay(this.after);
}

/// Decides, for each user message about to be delivered, whether something
/// goes wrong with it. System messages (supervision, `sys` requests) and
/// replies to `ask` are never offered.
typedef FaultPolicy = Fault Function(Delivery delivery);

/// A [FaultPolicy] that drops, delays and crashes at random.
///
/// [drop], [delay] and [crash] are probabilities per delivery and must sum to
/// at most 1. A delayed message waits a random time up to [maxDelay].
/// [where] limits the faults to some deliveries.
FaultPolicy randomFaults({
  double drop = 0,
  double delay = 0,
  double crash = 0,
  Duration maxDelay = const Duration(milliseconds: 100),
  bool Function(Delivery delivery)? where,
}) {
  if (drop < 0 || delay < 0 || crash < 0 || drop + delay + crash > 1) {
    throw ArgumentError('Probabilities must be in 0..1 and sum to at most 1');
  }
  return (delivery) {
    if (where != null && !where(delivery)) return Fault.none;
    final roll = delivery.random.nextDouble();
    if (roll < drop) return Fault.drop;
    if (roll < drop + crash) return Fault.crash;
    if (roll < drop + crash + delay) {
      return Fault.delay(Duration(
          microseconds:
              1 + delivery.random.nextInt(max(1, maxDelay.inMicroseconds))));
    }
    return Fault.none;
  };
}

/// Thrown when the test is waiting and nothing is left that could wake it:
/// no actor has a message, and no timer is pending.
///
/// Usual causes: waiting for a reply that was never sent, or for real I/O.
/// A simulation runs in one synchronous stretch, so sockets, files, other
/// isolates and futures created outside it never complete inside it.
class SimulationDeadlock extends Error {
  final Duration elapsed;
  SimulationDeadlock(this.elapsed);

  @override
  String toString() =>
      'SimulationDeadlock: the test is still waiting at +${_ms(elapsed)}, '
      'but no actor has a message to handle and no timer is pending';
}

/// Thrown when a simulation does not end within its step or time limit,
/// usually because actors keep each other busy forever.
class SimulationLimitExceeded extends Error {
  final String limit;
  SimulationLimitExceeded(this.limit);

  @override
  String toString() => 'SimulationLimitExceeded: $limit';
}

/// Thrown by [explore] and [checkCommands]: the test failed under [seed].
class SimulationFailure implements Exception {
  /// The seed to replay.
  final int seed;

  /// What the test failed with.
  final Object error;
  final StackTrace stackTrace;

  /// The scheduling decisions of the failing run.
  final List<String> trace;

  /// The commands of a [checkCommands] run, up to the one that failed.
  final List<Object?>? commands;

  SimulationFailure(this.seed, this.error, this.stackTrace, this.trace,
      {this.commands});

  @override
  String toString() {
    final shown = trace.length > 25 ? trace.sublist(trace.length - 25) : trace;
    return [
      'Failed under seed $seed: $error',
      if (commands != null) ...[
        'Commands:',
        for (final command in commands!) '  $command',
      ],
      'Last ${shown.length} of ${trace.length} scheduling steps:',
      for (final line in shown) '  $line',
      'Replay this run with seed: $seed.',
    ].join('\n');
  }
}

String _ms(Duration d) => '${(d.inMicroseconds / 1000).toStringAsFixed(3)}ms';

String _short(Object? value) {
  final text = '$value'.replaceAll('\n', ' ');
  return text.length > 60 ? '${text.substring(0, 57)}...' : text;
}

class _SimTimer implements Timer {
  final Simulation _sim;
  final Zone _zone;
  final Duration? _period;
  final void Function()? _once;
  final void Function(Timer)? _repeat;
  final int _seq;
  Duration _due;
  bool _active = true;
  int _tick = 0;

  _SimTimer(this._sim, this._zone, this._due, this._seq,
      {Duration? period, void Function()? once, void Function(Timer)? repeat})
      : _period = period,
        _once = once,
        _repeat = repeat;

  @override
  bool get isActive => _active;

  @override
  int get tick => _tick;

  @override
  void cancel() {
    _active = false;
    _sim._timers.remove(this);
  }

  void _fire() {
    _tick++;
    final period = _period;
    if (period == null) {
      cancel();
      _zone.runGuarded(_once!);
    } else {
      _due += period;
      _zone.runUnaryGuarded(_repeat!, this);
    }
  }
}

/// One run of an actor system under a seeded scheduler with virtual time.
/// Created by [simulate]; the test receives it as its argument.
///
/// What is simulated:
///
/// - **Scheduling.** One message is handed to one actor at a time, and which
///   actor goes next is drawn from [random]. Between two deliveries every
///   handler runs until it has to wait.
/// - **Time.** Timers, `Future.delayed` and timeouts run on a virtual clock
///   that jumps ahead whenever nothing else can happen, so a test that waits
///   an hour finishes at once. Timers due at the same moment fire in random
///   order, interleaved with message deliveries.
///
/// What is not: `DateTime.now()` and `Stopwatch` read the real clock (restart
/// budgets do follow virtual time), and
/// anything outside the isolate (I/O, other isolates) never completes.
class Simulation {
  /// The seed this run was started with.
  final int seed;

  /// The source of every random decision in this run. Use it for the test's
  /// own random choices, so that they are replayed along with the seed.
  final Random random;

  final FaultPolicy? _faults;
  final int _maxSteps;
  final Duration _maxTime;

  late final LocalActorSystem _system;
  late final Zone _zone;

  /// Every simulated system: [_system] first, then those from [addSystem].
  final _systems = <LocalActorSystem>[];

  final _microtasks = Queue<void Function()>();
  final _timers = <_SimTimer>[];
  final _settling = <Completer<void>>[];
  final _trace = <String>[];
  Duration _now = Duration.zero;
  int _timerSeq = 0;
  int _steps = 0;
  bool _faultsOn = true;
  (Object, StackTrace)? _uncaught;

  Simulation._(this.seed, this._faults, this._maxSteps, this._maxTime)
      : random = Random(seed);

  /// The simulated actor system. It is shut down when the test returns.
  LocalActorSystem get system => _system;

  /// Creates another actor system in the same simulation, for tests of
  /// several nodes. All systems share the scheduler, the clock and the seed,
  /// and all are shut down when the test returns.
  LocalActorSystem addSystem([ActorSystemConfig? config]) {
    final system = _zone.run(() => LocalActorSystem.stepped(
        config ?? ActorSystemConfig(logCollector: const NoOpLogCollector())));
    _systems.add(system);
    return system;
  }

  /// Virtual time since the run started.
  Duration get elapsed => _now;

  /// How many scheduling steps (deliveries and timers) have run.
  int get steps => _steps;

  /// The scheduling decisions so far, one line each.
  List<String> get trace => List.unmodifiable(_trace);

  /// Completes when the system has gone quiet: no actor has a message it can
  /// handle and no timer is due at the current virtual time. Timers set for
  /// later do not count, and time does not advance.
  ///
  /// This replaces the short sleeps tests use to "let the actors finish".
  Future<void> settle() {
    final done = Completer<void>();
    _settling.add(done);
    return done.future;
  }

  /// Completes after [duration] of virtual time.
  Future<void> wait(Duration duration) => Future<void>.delayed(duration);

  ZoneSpecification get _spec => ZoneSpecification(
        scheduleMicrotask: (self, parent, zone, f) =>
            _microtasks.add(() => zone.runGuarded(f)),
        createTimer: (self, parent, zone, duration, f) => _add(_SimTimer(
            this, zone, _now + _positive(duration), _timerSeq++,
            once: f)),
        createPeriodicTimer: (self, parent, zone, period, f) => _add(_SimTimer(
            this, zone, _now + _positive(period), _timerSeq++,
            period: _positive(period), repeat: f)),
        handleUncaughtError: (self, parent, zone, error, stackTrace) =>
            _uncaught ??= (error, stackTrace),
      );

  static Duration _positive(Duration d) => d.isNegative ? Duration.zero : d;

  _SimTimer _add(_SimTimer timer) {
    _timers.add(timer);
    return timer;
  }

  void _flushMicrotasks() {
    var count = 0;
    while (_microtasks.isNotEmpty) {
      _microtasks.removeFirst()();
      if (++count > 10000000) {
        throw SimulationLimitExceeded(
            'ten million microtasks ran without a pause');
      }
    }
    final uncaught = _uncaught;
    if (uncaught != null) {
      _uncaught = null;
      Error.throwWithStackTrace(uncaught.$1, uncaught.$2);
    }
  }

  StepFault _onDelivery(StepDelivery delivery) {
    final message = delivery.message;
    final payload = message is LocalMessage ? message.payload : message;
    final sender = message is LocalMessage ? message.sender : null;
    final target = delivery.target;
    if (delivery.isSystem) {
      _trace.add('+${_ms(_now)} system  ${target.id} <- '
          '${_short(payload.runtimeType)}');
      return StepFault.none;
    }
    final policy = _faults;
    final fault = policy == null || !_faultsOn
        ? Fault.none
        : policy(Delivery._(target, payload, sender, random, _now));
    switch (fault) {
      case _Delay(:final after):
        _trace.add('+${_ms(_now)} delay   ${target.id} <- ${_short(payload)} '
            'by ${_ms(after)}');
        _zone.createTimer(after, () => target.tell(message));
        return StepFault.skip;
      case _Simple(:final name):
        _trace.add(
            '+${_ms(_now)} ${name == 'none' ? 'deliver' : name.padRight(7)} '
            '${target.id} <- ${_short(payload)}');
        return switch (name) {
          'drop' => StepFault.skip,
          'crash' => StepFault.crash,
          _ => StepFault.none,
        };
    }
  }

  /// Runs until [finished] says so.
  void _drive(bool Function() finished) {
    while (true) {
      _flushMicrotasks();
      if (finished()) return;

      final runnable = [
        for (final system in _systems)
          for (final id in system.runnableActors) (system, id)
      ];
      final due = [
        for (final timer in _timers)
          if (timer._due <= _now) timer
      ]..sort((a, b) => a._seq.compareTo(b._seq));
      final choices = runnable.length + due.length;

      if (choices > 0) {
        if (++_steps > _maxSteps) {
          throw SimulationLimitExceeded('more than $_maxSteps steps');
        }
        final pick = random.nextInt(choices);
        if (pick < runnable.length) {
          final (system, id) = runnable[pick];
          system.step(id, fault: _onDelivery);
        } else {
          _trace.add('+${_ms(_now)} timer');
          due[pick - runnable.length]._fire();
        }
        continue;
      }

      if (_settling.isNotEmpty) {
        final waiting = _settling.toList();
        _settling.clear();
        for (final done in waiting) {
          done.complete();
        }
        continue;
      }

      if (_timers.isEmpty) throw SimulationDeadlock(_now);
      final next = _timers.map((t) => t._due).reduce((a, b) => a < b ? a : b);
      if (next > _maxTime) {
        throw SimulationLimitExceeded(
            'virtual time passed ${_maxTime.inSeconds} s; a periodic timer '
            'may be keeping the run alive');
      }
      _now = next;
    }
  }

  T _run<T>(
      FutureOr<T> Function(Simulation sim) body, ActorSystemConfig? config) {
    _zone = Zone.current.fork(
        specification: _spec,
        zoneValues: {clockKey: () => _now.inMicroseconds});
    var done = false;
    T? result;
    (Object, StackTrace)? failure;

    _zone.run(() {
      _system = LocalActorSystem.stepped(
          config ?? ActorSystemConfig(logCollector: const NoOpLogCollector()));
      _systems.add(_system);
      Future<T>.sync(() => body(this)).then((value) {
        result = value;
        done = true;
      }, onError: (Object e, StackTrace s) {
        failure = (e, s);
        done = true;
      });
    });

    try {
      _drive(() => done);
    } catch (e, s) {
      failure ??= (e, s);
    }

    // Shut down without injected faults, and without letting a second
    // problem hide the first.
    _faultsOn = false;
    _settling.clear();
    var down = false;
    try {
      _zone.run(() => Future.wait(
              [for (final system in _systems.reversed) system.shutdown()])
          .whenComplete(() => down = true));
      _drive(() => down);
    } catch (e, s) {
      if (e is! SimulationDeadlock) failure ??= (e, s);
    }
    _timers.clear();
    _microtasks.clear();

    final failed = failure;
    if (failed != null) Error.throwWithStackTrace(failed.$1, failed.$2);
    return result as T;
  }
}

/// Runs [body] against a simulated actor system and returns its result.
///
/// The whole run happens inside this call: [body] may be asynchronous, but
/// `simulate` itself is not, and virtual time costs nothing. The same [seed]
/// gives the same run every time, as long as the test takes its own random
/// choices from [Simulation.random].
///
/// [faults] interferes with message deliveries; see [randomFaults].
/// [config] replaces the system's configuration (by default logging is off).
/// The run is abandoned with [SimulationLimitExceeded] after [maxSteps]
/// deliveries and timers, or [maxTime] of virtual time.
T simulate<T>(
  FutureOr<T> Function(Simulation sim) body, {
  int seed = 0,
  FaultPolicy? faults,
  ActorSystemConfig? config,
  int maxSteps = 100000,
  Duration maxTime = const Duration(hours: 1),
}) =>
    Simulation._(seed, faults, maxSteps, maxTime)._run(body, config);

/// Runs [body] under [seeds] different seeds, starting at [firstSeed], and
/// stops at the first one it fails under.
///
/// The failure is rethrown as a [SimulationFailure] that names the seed and
/// shows the last scheduling steps. Pass that seed to [simulate] to get the
/// same run again.
void explore(
  FutureOr<void> Function(Simulation sim) body, {
  int seeds = 100,
  int firstSeed = 0,
  FaultPolicy? faults,
  ActorSystemConfig Function()? config,
  int maxSteps = 100000,
  Duration maxTime = const Duration(hours: 1),
}) {
  for (var seed = firstSeed; seed < firstSeed + seeds; seed++) {
    final sim = Simulation._(seed, faults, maxSteps, maxTime);
    try {
      sim._run(body, config?.call());
    } catch (e, s) {
      throw SimulationFailure(seed, e, s, sim._trace);
    }
  }
}

/// A property test over sequences of commands.
///
/// For each seed, [setup] creates the thing under test in a fresh simulated
/// system and [model] creates a plain-Dart description of how it should
/// behave. Then, [commands] times, [generate] draws a command (it may look
/// at the model to pick a sensible one) and [apply] runs it against both,
/// checks that they agree, and returns the model's next value.
///
/// A failure is rethrown as a [SimulationFailure] with the seed and the
/// commands that led to it. Sequences are not shrunk.
void checkCommands<S, M, C>({
  required FutureOr<S> Function(Simulation sim) setup,
  required M Function() model,
  required C Function(Random random, M model) generate,
  required FutureOr<M> Function(Simulation sim, S subject, M model, C command)
      apply,
  int seeds = 100,
  int commands = 30,
  int firstSeed = 0,
  FaultPolicy? faults,
  int maxSteps = 100000,
}) {
  for (var seed = firstSeed; seed < firstSeed + seeds; seed++) {
    final sim = Simulation._(seed, faults, maxSteps, const Duration(hours: 1));
    final history = <Object?>[];
    try {
      sim._run((sim) async {
        final subject = await setup(sim);
        var current = model();
        for (var i = 0; i < commands; i++) {
          final command = generate(sim.random, current);
          history.add(command);
          current = await apply(sim, subject, current, command);
        }
      }, null);
    } catch (e, s) {
      throw SimulationFailure(seed, e, s, sim._trace, commands: history);
    }
  }
}
