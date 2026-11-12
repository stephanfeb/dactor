// What a hop to another node costs, over loopback TCP, with both nodes in
// this one process: one-way tells per second and time per ask.
//
// Run:  dart run tool/throughput.dart
import 'package:dactor/dactor.dart';
import 'package:dactor_remote/dactor_remote.dart';
import 'package:dactor_remote/tcp.dart';

class Summer extends Actor {
  int total = 0;

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is int) {
      total += message;
    } else {
      context.sender?.tell(total);
    }
  }
}

Future<void> measure(String name, ActorRef ref) async {
  for (var i = 0; i < 20000; i++) {
    ref.tell(1);
  }
  await ref.ask<int>('read', const Duration(minutes: 1));

  const n = 200000;
  var watch = Stopwatch()..start();
  for (var i = 0; i < n; i++) {
    ref.tell(1);
  }
  await ref.ask<int>('read', const Duration(minutes: 1));
  final oneWay = n / watch.elapsedMicroseconds * 1e6;

  const asks = 10000;
  watch = Stopwatch()..start();
  for (var i = 0; i < asks; i++) {
    await ref.ask<int>('read');
  }
  print('${name.padRight(8)} '
      '${(oneWay / 1000).toStringAsFixed(0).padLeft(5)} k msg/s one way, '
      '${(watch.elapsedMicroseconds / asks).toStringAsFixed(1).padLeft(6)} '
      'us per ask');
}

Future<void> main() async {
  final quiet = ActorSystemConfig(logCollector: const NoOpLogCollector());
  final sa = LocalActorSystem(quiet), sb = LocalActorSystem(quiet);
  final a = RemoteNode(sa, await TcpTransport.bind());
  final b = RemoteNode(sb, await TcpTransport.bind());
  final summer = await sb.spawn('summer', () => Summer());

  await measure('local', summer);
  await measure('tcp', a.resolve(b.uriOf(summer)));

  await a.close();
  await b.close();
  await sa.shutdown();
  await sb.shutdown();
}
