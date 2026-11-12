// Measures what the isolate boundary costs an actor: one-way throughput and
// ask round trips, for the same actor placed in the system's isolate and in
// one of its own.
//
// Run:  dart run tool/probes/isolated_throughput.dart
import 'package:dactor/dactor.dart';

class Summer extends Actor {
  int total = 0;

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is int) {
      total += message;
    } else {
      context.sender?.tell(LocalMessage(payload: total));
    }
  }
}

Future<void> measure(String name, Actor Function() factory) async {
  final system = LocalActorSystem();
  final ref = await system.spawn('summer', factory);
  const n = 200000;
  for (var i = 0; i < 20000; i++) {
    ref.tell(LocalMessage(payload: 1));
  }
  await ref.ask<int>(LocalMessage(payload: 'read'));

  var watch = Stopwatch()..start();
  for (var i = 0; i < n; i++) {
    ref.tell(LocalMessage(payload: 1));
  }
  await ref.ask<int>(LocalMessage(payload: 'read'), const Duration(minutes: 1));
  final oneWay = n / watch.elapsedMicroseconds * 1e6;

  const asks = 20000;
  watch = Stopwatch()..start();
  for (var i = 0; i < asks; i++) {
    await ref.ask<int>(LocalMessage(payload: 'read'));
  }
  final perAsk = watch.elapsedMicroseconds / asks;
  print('${name.padRight(9)} ${(oneWay / 1000).toStringAsFixed(0).padLeft(5)} '
      'k msg/s one way, ${perAsk.toStringAsFixed(1).padLeft(6)} us per ask');
  await system.shutdown();
}

Future<void> main() async {
  await measure('shared', Summer.new);
  await measure('isolated', () => Isolated(Summer.new));
}
