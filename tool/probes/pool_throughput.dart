// Measures one-way throughput to a single actor and to round-robin pools of
// several sizes. The clock stops when the last message has been handled.
import 'dart:async';

import 'package:dactor/dactor.dart';

int _handled = 0;
Completer<void>? _done;
int _target = 0;

class Counter extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {
    if (++_handled == _target) _done!.complete();
  }
}

Future<double> run(LocalActorSystem system, ActorRef ref, int n) async {
  _handled = 0;
  _target = n;
  _done = Completer<void>();
  final sw = Stopwatch()..start();
  for (var i = 0; i < n; i++) {
    ref.tell(i);
  }
  await _done!.future;
  return n / (sw.elapsedMicroseconds / 1e6);
}

Future<void> main() async {
  const n = 200000;
  final system = LocalActorSystem(
      ActorSystemConfig(logCollector: const NoOpLogCollector()));
  final single = await system.spawn('single', () => Counter());
  final pools = {
    for (final w in [1, 4, 16])
      w: await system.spawn('pool-$w', () => Counter(),
          pool: Pool(workerCount: w)),
  };
  for (var round = 0; round < 3; round++) {
    final s = await run(system, single, n);
    final line = StringBuffer('single ${(s / 1000).round()}k');
    for (final e in pools.entries) {
      final p = await run(system, e.value, n);
      line.write('  pool(${e.key}) ${(p / 1000).round()}k');
    }
    print(line);
  }
  await system.shutdown();
}
