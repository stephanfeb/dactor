// What a hop to another node costs over libp2p (UDX, Noise, Yamux) on
// loopback, against plain TCP, with all nodes in this one process:
// one-way tells per second and time per ask.
//
// Run:  dart run tool/throughput.dart

import 'package:dactor/dactor.dart';
import 'package:dactor_libp2p/dactor_libp2p.dart';
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

  Future<Libp2pTransport> libp2p() async => Libp2pTransport(
      await startHost(
          listen: const ['/ip4/127.0.0.1/udp/0/udx'], allowLoopback: true),
      closeHost: true);
  final ta = await libp2p(), tb = await libp2p();
  await ta.addAddresses(tb.addresses);
  final sc = LocalActorSystem(quiet), sd = LocalActorSystem(quiet);
  final c = RemoteNode(sc, ta), d = RemoteNode(sd, tb);
  final summer2 = await sd.spawn('summer', () => Summer());
  await measure('libp2p', c.resolve(d.uriOf(summer2)));

  for (final node in [a, b, c, d]) {
    await node.close();
  }
  for (final system in [sa, sb, sc, sd]) {
    await system.shutdown();
  }
}
