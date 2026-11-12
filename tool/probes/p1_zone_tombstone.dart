// Probe P1 (doc/otp-gap-roadmap.md): can a Zone stand in for a process
// boundary inside one isolate?
//
// An actor's code runs in a forked zone. "Killing" the actor flips a flag
// that turns every later callback in that zone into a no-op. The probe checks
// which kinds of pending work that actually stops, what leaks, and what the
// wrapper costs per message.
//
// Run:  dart run tool/probes/p1_zone_tombstone.dart
//       dart compile exe tool/probes/p1_zone_tombstone.dart -o /tmp/p1 && /tmp/p1
import 'dart:async';
import 'dart:io';

/// How the zone intercepts callbacks.
enum Mode {
  /// Wrap each callback when it is registered (registerCallback family).
  register,

  /// Intercept each callback when it is run (run family).
  run,
}

class Cell {
  final Mode mode;
  final bool cancelTimers;
  bool dead = false;
  int suppressed = 0;
  int swallowedErrors = 0;
  final errors = <Object>[];
  final _timers = <Timer>{};
  late final Zone zone;

  Cell(this.mode, {this.cancelTimers = false}) {
    zone = Zone.current.fork(
      specification: ZoneSpecification(
        handleUncaughtError: (self, parent, zone, error, stack) {
          if (dead) {
            swallowedErrors++;
          } else {
            errors.add(error);
          }
        },
        createTimer: (self, parent, zone, duration, f) {
          late Timer t;
          t = parent.createTimer(zone, duration, () {
            _timers.remove(t);
            f();
          });
          _timers.add(t);
          return t;
        },
        createPeriodicTimer: (self, parent, zone, period, f) {
          final t = parent.createPeriodicTimer(zone, period, f);
          _timers.add(t);
          return t;
        },
        registerCallback: mode != Mode.register
            ? null
            : <R>(self, parent, zone, f) {
                final g = parent.registerCallback(zone, f);
                return () {
                  if (dead) {
                    suppressed++;
                    return null as R;
                  }
                  return g();
                };
              },
        registerUnaryCallback: mode != Mode.register
            ? null
            : <R, T>(self, parent, zone, f) {
                final g = parent.registerUnaryCallback(zone, f);
                return (arg) {
                  if (dead) {
                    suppressed++;
                    return null as R;
                  }
                  return g(arg);
                };
              },
        registerBinaryCallback: mode != Mode.register
            ? null
            : <R, T1, T2>(self, parent, zone, f) {
                final g = parent.registerBinaryCallback(zone, f);
                return (a, b) {
                  if (dead) {
                    suppressed++;
                    return null as R;
                  }
                  return g(a, b);
                };
              },
        run: mode != Mode.run
            ? null
            : <R>(self, parent, zone, f) {
                if (dead) {
                  suppressed++;
                  return null as R;
                }
                return parent.run(zone, f);
              },
        runUnary: mode != Mode.run
            ? null
            : <R, T>(self, parent, zone, f, arg) {
                if (dead) {
                  suppressed++;
                  return null as R;
                }
                return parent.runUnary(zone, f, arg);
              },
        runBinary: mode != Mode.run
            ? null
            : <R, T1, T2>(self, parent, zone, f, a, b) {
                if (dead) {
                  suppressed++;
                  return null as R;
                }
                return parent.runBinary(zone, f, a, b);
              },
      ),
    );
  }

  int kill() {
    dead = true;
    var cancelled = 0;
    if (cancelTimers) {
      for (final t in _timers) {
        t.cancel();
        cancelled++;
      }
      _timers.clear();
    }
    return cancelled;
  }
}

Future<void> settle([int ms = 80]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

typedef Scenario = ({
  String name,
  // Returns true if the dead actor's code was stopped (nothing leaked).
  Future<bool> Function(Cell cell) body,
  // What we hope for; `false` marks a documented limit.
  bool expectStopped,
});

final scenarios = <Scenario>[
  (
    name: 'await Future.delayed, code after it',
    expectStopped: true,
    body: (cell) async {
      var leaked = false;
      cell.zone.run(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        leaked = true;
      });
      cell.kill();
      await settle();
      return !leaked;
    },
  ),
  (
    name: 'finally block around a pending await',
    expectStopped: true,
    body: (cell) async {
      var finallyRan = false;
      cell.zone.run(() async {
        try {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        } finally {
          finallyRan = true;
        }
      });
      cell.kill();
      await settle();
      return !finallyRan;
    },
  ),
  (
    name: 'nested async calls (a awaits b awaits timer)',
    expectStopped: true,
    body: (cell) async {
      var leaked = 0;
      Future<void> b() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        leaked++;
      }

      Future<void> a() async {
        await b();
        leaked++;
      }

      cell.zone.run(a);
      cell.kill();
      await settle();
      return leaked == 0;
    },
  ),
  (
    name: 'one-shot Timer',
    expectStopped: true,
    body: (cell) async {
      var leaked = false;
      cell.zone.run(() {
        Timer(const Duration(milliseconds: 20), () => leaked = true);
      });
      cell.kill();
      await settle();
      return !leaked;
    },
  ),
  (
    name: 'periodic Timer',
    expectStopped: true,
    body: (cell) async {
      var ticks = 0;
      late Timer t;
      cell.zone.run(() {
        t = Timer.periodic(const Duration(milliseconds: 5), (_) => ticks++);
      });
      cell.kill();
      await settle();
      t.cancel();
      return ticks == 0;
    },
  ),
  (
    name: 'scheduleMicrotask queued before the kill',
    expectStopped: true,
    body: (cell) async {
      var leaked = false;
      cell.zone.run(() => scheduleMicrotask(() => leaked = true));
      cell.kill();
      await settle(10);
      return !leaked;
    },
  ),
  (
    name: 'stream subscription fed from outside the zone',
    expectStopped: true,
    body: (cell) async {
      final controller = StreamController<int>();
      var seen = 0;
      cell.zone.run(() => controller.stream.listen((_) => seen++));
      controller.add(1);
      await settle(10);
      final before = seen;
      cell.kill();
      controller
        ..add(2)
        ..add(3);
      await settle(10);
      return before == 1 && seen == 1;
    },
  ),
  (
    name: 'await on a completer completed from outside',
    expectStopped: true,
    body: (cell) async {
      final gate = Completer<int>();
      var leaked = false;
      cell.zone.run(() async {
        await gate.future;
        leaked = true;
      });
      cell.kill();
      gate.complete(1);
      await settle(10);
      return !leaked;
    },
  ),
  (
    name: 'await on real file I/O',
    expectStopped: true,
    body: (cell) async {
      var leaked = false;
      cell.zone.run(() async {
        await File(Platform.resolvedExecutable).stat();
        leaked = true;
      });
      cell.kill();
      await settle();
      return !leaked;
    },
  ),
  (
    name: '.then<int> chain (non-nullable result)',
    expectStopped: true,
    body: (cell) async {
      var leaked = 0;
      cell.zone.run(() {
        Future<void>.delayed(const Duration(milliseconds: 20)).then<int>((_) {
          leaked++;
          return 1;
        }).then((v) {
          leaked++;
        });
      });
      cell.kill();
      await settle();
      return leaked == 0;
    },
  ),
  (
    name: 'async* generator being consumed',
    expectStopped: true,
    body: (cell) async {
      var produced = 0;
      Stream<int> gen() async* {
        while (true) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
          produced++;
          yield produced;
        }
      }

      cell.zone.run(() async {
        await for (final _ in gen()) {}
      });
      await settle(22);
      final before = produced;
      cell.kill();
      await settle();
      return before > 0 && produced == before;
    },
  ),
  (
    name: 'LIMIT: work started through Zone.root.run',
    expectStopped: false,
    body: (cell) async {
      var leaked = false;
      cell.zone.run(() {
        Zone.root.run(() {
          Timer(const Duration(milliseconds: 20), () => leaked = true);
        });
      });
      cell.kill();
      await settle();
      return !leaked;
    },
  ),
  (
    name: 'LIMIT: a synchronous loop already running',
    expectStopped: false,
    body: (cell) async {
      // The kill can only land between callbacks. Here it is issued from a
      // timer that cannot fire until the loop gives the isolate back.
      var iterations = 0;
      Timer(Duration.zero, cell.kill);
      cell.zone.run(() {
        final sw = Stopwatch()..start();
        while (sw.elapsedMilliseconds < 20) {
          iterations++;
        }
      });
      final ranToEnd = iterations > 0 && !cell.dead;
      await settle(5);
      return !ranToEnd;
    },
  ),
];

Future<void> attribution(Mode mode) async {
  final cell = Cell(mode);
  cell.zone.run(() {
    // Unawaited, so nothing in the actor's own code can catch it.
    Future<void>.delayed(const Duration(milliseconds: 5))
        .then((_) => throw StateError('lost future'));
    Timer(const Duration(milliseconds: 5), () => throw StateError('timer'));
  });
  await settle(30);
  print('  errors attributed to the live actor: ${cell.errors.length} of 2');

  cell.zone.run(() {
    Future<void>.delayed(const Duration(milliseconds: 5))
        .then((_) => throw StateError('after death'));
  });
  cell.kill();
  await settle(30);
  print('  errors seen after the kill: ${cell.errors.length - 2} '
      '(swallowed ${cell.swallowedErrors}, suppressed ${cell.suppressed})');
}

Future<void> outerAwaiter(Mode mode) async {
  final cell = Cell(mode);
  final handler = cell.zone.run(() async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });
  cell.kill();
  var completed = false;
  await handler
      .then((_) => completed = true)
      .timeout(const Duration(milliseconds: 100), onTimeout: () => false);
  print('  future returned by a killed handler completes: $completed');

  // Errors do not cross from one error zone to another. A future created in
  // the actor's zone delivers its error to the zone's handler, not to a
  // listener outside; the outside listener hangs. A completer created on the
  // listening side and completed from inside does carry the error across.
  final live = Cell(mode);
  final direct = live.zone.run(() async {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    throw StateError('from the actor');
  });
  var directSaw = 'nothing';
  direct.then((_) => directSaw = 'a value',
      onError: (Object e) => directSaw = 'the error');
  final bridge = Completer<void>();
  live.zone.run(() {
    Future<void>.delayed(const Duration(milliseconds: 5))
        .then<void>((_) => throw StateError('bridged'))
        .then(bridge.complete, onError: bridge.completeError);
  });
  var bridgedSaw = 'nothing';
  bridge.future.then((_) => bridgedSaw = 'a value',
      onError: (Object e) => bridgedSaw = 'the error');
  await settle(30);
  print('  outside listener on an actor-zone future that fails sees: '
      '$directSaw (zone handler got ${live.errors.length})');
  print('  outside listener on a bridging completer sees: $bridgedSaw');
}

Future<double> bench(String label, Zone? zone, int n, bool async_) async {
  var counter = 0;
  Future<void> asyncHandler() async {
    await null;
    counter++;
  }

  void syncHandler() {
    counter++;
  }

  Future<void> loop(int count) async {
    for (var i = 0; i < count; i++) {
      if (async_) {
        await (zone == null ? asyncHandler() : zone.run(asyncHandler));
      } else {
        zone == null ? syncHandler() : zone.run(syncHandler);
      }
    }
  }

  await loop(n ~/ 10); // warm up
  final sw = Stopwatch()..start();
  await loop(n);
  final ns = sw.elapsedMicroseconds * 1000 / n;
  print('  ${label.padRight(34)} ${ns.toStringAsFixed(1).padLeft(8)} ns/msg');
  return ns;
}

Future<void> main() async {
  final outerErrors = <Object>[];
  await runZonedGuarded(() async {
    print('Dart ${Platform.version.split(' ').first}, '
        '${Platform.executable.endsWith('dart') ? 'JIT' : 'AOT'}\n');

    for (final mode in Mode.values) {
      print('== mode: ${mode.name} ==');
      for (final s in scenarios) {
        final cell = Cell(mode);
        final stopped = await s.body(cell);
        final verdict = stopped ? 'stopped' : 'LEAKED ';
        final note = stopped == s.expectStopped ? '' : '   <-- unexpected';
        print('  $verdict  ${s.name}$note');
      }
      await attribution(mode);
      await outerAwaiter(mode);

      final cell = Cell(mode, cancelTimers: true);
      cell.zone.run(() {
        Timer(const Duration(seconds: 30), () {});
        Timer.periodic(const Duration(seconds: 30), (_) {});
      });
      print('  timers cancelled by kill: ${cell.kill()} of 2\n');
    }

    print('== cost per message ==');
    const n = 2000000;
    for (final async_ in [false, true]) {
      print(async_ ? ' handler with one await:' : ' synchronous handler:');
      await bench('no zone', null, n, async_);
      await bench('forked zone, no hooks', Zone.current.fork(), n, async_);
      await bench(
          'tombstone zone, register mode', Cell(Mode.register).zone, n, async_);
      await bench('tombstone zone, run mode', Cell(Mode.run).zone, n, async_);
    }
  }, (e, s) => outerErrors.add(e));

  print('\nerrors that escaped to the enclosing zone: ${outerErrors.length}');
  for (final e in outerErrors.take(5)) {
    print('  $e');
  }
}
