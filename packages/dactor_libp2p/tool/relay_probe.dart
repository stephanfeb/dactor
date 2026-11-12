import 'dart:io';

import 'package:dactor_libp2p/dactor_libp2p.dart';

/// Reserves on a public relay and prints the addresses this host gets.
/// dart run tool/relay_probe.dart /ip4/<ip>/udp/<port>/udx/p2p/<id>
Future<void> main(List<String> args) async {
  final host = await startHost(relay: RelayRole.reserve, relays: args);
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(seconds: 1));
    final circuit = host.addrs.where((a) => a.toString().contains('p2p-circuit'));
    if (circuit.isNotEmpty) {
      print('reserved after ${i + 1} s: ${circuit.join(', ')}');
      break;
    }
  }
  print('all: ${host.addrs.join('\n     ')}');
  await host.close();
  exitCode = 0;
}
