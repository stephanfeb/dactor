// Probe P2 (doc/otp-gap-roadmap.md): does Isolate.kill(immediate) stop an
// isolate that never returns to its event loop?
//
// Each case spawns an isolate that gets stuck in a different way, waits for
// it to report that it has started, kills it, and measures how long the exit
// port takes to fire. The main isolate must stay responsive throughout.
//
// Run:  dart run tool/probes/p2_isolate_kill.dart
//       dart compile exe tool/probes/p2_isolate_kill.dart -o /tmp/p2 && /tmp/p2
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

void emptyLoop(SendPort ready) {
  ready.send(null);
  while (true) {}
}

void arithmeticLoop(SendPort ready) {
  ready.send(null);
  var x = 0;
  while (true) {
    x = (x * 31 + 7) & 0xffff;
  }
}

int _step(int x) => (x * 31 + 7) & 0xffff;

void callingLoop(SendPort ready) {
  ready.send(null);
  var x = 0;
  while (true) {
    x = _step(x);
  }
}

void allocatingLoop(SendPort ready) {
  ready.send(null);
  var list = <int>[];
  while (true) {
    list = [...list.take(100), list.length];
  }
}

void recursion(SendPort ready) {
  ready.send(null);
  int fib(int n) => n < 2 ? n : fib(n - 1) + fib(n - 2);
  while (true) {
    fib(30);
  }
}

void microtaskLoop(SendPort ready) {
  ready.send(null);
  void again() => scheduleMicrotask(again);
  again();
}

Future<void> awaitLoop(SendPort ready) async {
  ready.send(null);
  while (true) {
    await null;
  }
}

void nativeSleep(SendPort ready) {
  ready.send(null);
  sleep(const Duration(seconds: 3));
  while (true) {}
}

// Note: with an empty inner `while (true) {}` here, Dart 3.11.5's optimising
// JIT aborts the whole VM while compiling this function (assertion in
// flow_graph_compiler.cc). That is a compiler bug in degenerate code, not a
// property of kill; the loop below does some work to stay clear of it.
void catchesEverything(SendPort ready) {
  ready.send(null);
  var x = 0;
  while (true) {
    try {
      while (true) {
        x = _step(x);
        if (x < 0) throw StateError('never');
      }
    } catch (_) {
      // A kill must not be catchable.
      x = 1;
    } finally {
      // Nor may a finally block keep the isolate alive.
      x = 2;
    }
  }
}

void idle(SendPort ready) {
  ReceivePort();
  ready.send(null);
}

Future<void> probe(String name, void Function(SendPort) entry,
    {Duration limit = const Duration(seconds: 6)}) async {
  final ready = ReceivePort();
  final exit = ReceivePort();
  final errors = ReceivePort();
  final isolate = await Isolate.spawn(entry, ready.sendPort,
      onExit: exit.sendPort, onError: errors.sendPort);
  var errorCount = 0;
  errors.listen((_) => errorCount++);
  await ready.first;
  // Let it get properly stuck (and JIT-optimised).
  await Future<void>.delayed(const Duration(milliseconds: 300));

  // The main isolate must keep running its own timers meanwhile.
  var ticks = 0;
  final ticker =
      Timer.periodic(const Duration(milliseconds: 1), (_) => ticks++);

  final watch = Stopwatch()..start();
  isolate.kill(priority: Isolate.immediate);
  final died =
      await exit.first.then((_) => true).timeout(limit, onTimeout: () => false);
  watch.stop();
  ticker.cancel();
  errors.close();

  final outcome = died
      ? 'killed in ${(watch.elapsedMicroseconds / 1000).toStringAsFixed(2)} ms'
      : 'STILL ALIVE after ${limit.inSeconds} s';
  print('${name.padRight(22)} $outcome'
      '${errorCount > 0 ? '  (onError fired $errorCount times)' : ''}'
      '  [main ticked $ticks times]');
}

Future<void> main() async {
  final aot = !Platform.executable.endsWith('dart');
  print('Dart ${Platform.version.split(' ').first}, '
      '${aot ? 'AOT' : 'JIT'}, ${Platform.operatingSystem}\n');
  await probe('idle', idle);
  await probe('empty loop', emptyLoop);
  await probe('arithmetic loop', arithmeticLoop);
  await probe('calling loop', callingLoop);
  await probe('allocating loop', allocatingLoop);
  await probe('recursion', recursion);
  await probe('microtask loop', microtaskLoop);
  await probe('await loop', awaitLoop);
  await probe('try/catch/finally', catchesEverything);
  await probe('native sleep(3s)', nativeSleep);

  // Many at once: does killing scale, and does one stuck isolate delay the
  // death of another?
  final exits = <Future<void>>[];
  final isolates = <Isolate>[];
  for (var i = 0; i < 8; i++) {
    final ready = ReceivePort();
    final exit = ReceivePort();
    isolates.add(await Isolate.spawn(arithmeticLoop, ready.sendPort,
        onExit: exit.sendPort));
    await ready.first;
    exits.add(exit.first);
  }
  final watch = Stopwatch()..start();
  for (final isolate in isolates) {
    isolate.kill(priority: Isolate.immediate);
  }
  final all = await Future.wait(exits)
      .then((_) => true)
      .timeout(const Duration(seconds: 6), onTimeout: () => false);
  print('\n8 spinning at once    '
      '${all ? 'all killed in ${watch.elapsedMilliseconds} ms' : 'NOT all killed'}');
  exit(0);
}
