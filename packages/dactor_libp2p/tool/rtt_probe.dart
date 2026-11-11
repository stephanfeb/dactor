// Probe: the round trip of 8 bytes on one libp2p stream (UDX, Noise,
// Yamux) on loopback, without dactor, to tell the stack's latency from the
// transport's.
import 'dart:io';
import 'dart:typed_data';

import 'package:dactor_libp2p/dactor_libp2p.dart';
import 'package:dart_libp2p/dart_libp2p.dart';

Future<void> main() async {
  Future<Host> host() => startHost(
      listen: const ['/ip4/127.0.0.1/udp/0/udx'], allowLoopback: true);
  final a = await host(), b = await host();
  b.setStreamHandler('/echo', (s, _) async {
    while (true) {
      final data = await s.read();
      if (data.isEmpty) return;
      await s.write(data);
    }
  });
  await a.peerStore.addrBook.addAddrs(b.id, b.addrs, const Duration(hours: 1));
  final s = await a.newStream(b.id, ['/echo'], Context());
  final ping = Uint8List(8);
  for (var i = 0; i < 200; i++) {
    await s.write(ping);
    await s.read();
  }
  const n = 2000;
  final watch = Stopwatch()..start();
  for (var i = 0; i < n; i++) {
    await s.write(ping);
    await s.read();
  }
  print('${(watch.elapsedMicroseconds / n).toStringAsFixed(1)} us per round trip');
  exit(0);
}
