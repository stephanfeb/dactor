// Probe: does a process exit after its libp2p host dialled another and
// both were closed? With dart_libp2p 4.12.0 it does not when the dialler
// has no listener, or when a stream was opened: a dial that does not reuse
// a listener's socket binds a UDP socket of its own (UDXTransport
// _performDial), and nothing closes it after a successful dial.
//
//   dart run tool/exit_probe.dart                    hangs
//   dart run tool/exit_probe.dart blisten            exits
//   dart run tool/exit_probe.dart blisten stream     hangs
import 'dart:typed_data';

import 'package:dactor_libp2p/dactor_libp2p.dart';
import 'package:dart_libp2p/dart_libp2p.dart';

Future<void> main(List<String> args) async {
  final w = Stopwatch()..start();
  final a = await startHost(
      listen: const ['/ip4/127.0.0.1/udp/0/udx'], allowLoopback: true);
  final b = await startHost(
      listen: args.contains('blisten')
          ? const ['/ip4/127.0.0.1/udp/0/udx']
          : const [],
      allowLoopback: true);
  await b.connect(AddrInfo(a.id, a.addrs));
  print('connected ${w.elapsedMilliseconds}');
  if (args.contains('stream')) {
    a.setStreamHandler('/x', (s, _) async {
      await s.read();
    });
    final s = await b.newStream(a.id, ['/x'], Context());
    await s.write(Uint8List(4));
    if (args.contains('reset')) await s.reset();
    if (args.contains('close')) await s.close();
  }
  await b.close();
  print('b closed ${w.elapsedMilliseconds}');
  await a.close();
  print('a closed ${w.elapsedMilliseconds}');
}
