// Probe: can three libp2p hosts on loopback carry a stream from A to B
// through relay R, when B does not listen on any direct address?
//
//   dart run tool/probe_relay.dart
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_libp2p/config/config.dart';
import 'package:dart_libp2p/dart_libp2p.dart' hide Option;
import 'package:dart_libp2p/p2p/security/noise/noise_protocol.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart';
import 'package:dart_libp2p/p2p/transport/multiplexing/multiplexer.dart';
import 'package:dart_libp2p/p2p/transport/multiplexing/yamux/session.dart';
import 'package:dart_libp2p/p2p/transport/udx_transport.dart';

Future<Host> host(
    {List<String> listen = const ['/ip4/127.0.0.1/udp/0/udx'],
    bool relayServer = false,
    bool relayClient = false,
    List<String> relays = const []}) async {
  final keys = await generateEd25519KeyPair();
  final cm = ConnectionManager();
  final options = <Option>[
    Libp2p.identity(keys),
    Libp2p.connManager(cm),
    Libp2p.transport(UDXTransport(connManager: cm)),
    Libp2p.security(await NoiseSecurity.create(keys)),
    Libp2p.muxer('/yamux/1.0.0', (conn, isClient) {
      return YamuxSession(
          conn as TransportConn, const MultiplexerConfig(), isClient, null);
    }),
    Libp2p.listenAddrs([for (final a in listen) MultiAddr(a)]),
    Libp2p.addrsFactory((addrs) => addrs),
    Libp2p.autoNAT(false),
    if (relayServer || relayClient) Libp2p.relay(true),
    if (relayServer) Libp2p.forceReachability(Reachability.public),
    if (relays.isNotEmpty) ...[
      Libp2p.autoRelay(true),
      Libp2p.relayServers(relays),
      Libp2p.forceReachability(Reachability.private),
    ],
  ];
  final h = await Libp2p.new_(options);
  await h.start();
  return h;
}

Future<void> main() async {
  final watch = Stopwatch()..start();
  final r = await host(relayServer: true);
  final rAddr = '${r.addrs.first}/p2p/${r.id.toBase58()}';
  print('relay ${r.id.toBase58()} at ${r.addrs}');

  final b = await host(listen: const [], relays: [rAddr]);
  print('B ${b.id.toBase58()} addrs ${b.addrs}');
  b.setStreamHandler('/probe/1.0.0', (stream, from) async {
    final data = await stream.read();
    await stream
        .write(Uint8List.fromList(utf8.encode('echo ${utf8.decode(data)}')));
    await stream.close();
  });

  // Wait for B's reservation to show as a circuit address.
  while (!b.addrs.any((a) => a.toString().contains('p2p-circuit'))) {
    if (watch.elapsed > const Duration(seconds: 60)) {
      print('no reservation after 60 s');
      break;
    }
    await Future.delayed(const Duration(milliseconds: 200));
  }
  print('${watch.elapsedMilliseconds} ms: B addrs ${b.addrs}');

  final a = await host(relayClient: true);
  final circuit = MultiAddr('$rAddr/p2p-circuit/p2p/${b.id.toBase58()}');
  await a.peerStore.addrBook.addAddrs(r.id, r.addrs, const Duration(hours: 1));
  await a.peerStore.addrBook
      .addAddrs(b.id, [circuit], const Duration(hours: 1));
  final s = await a.newStream(b.id, ['/probe/1.0.0'], Context());
  print('stream over ${s.conn.remoteMultiaddr}');
  await s.write(Uint8List.fromList(utf8.encode('hello')));
  print('reply: ${utf8.decode(await s.read())}');
  print('${watch.elapsedMilliseconds} ms total');
  await a.close();
  await b.close();
  await r.close();
}
