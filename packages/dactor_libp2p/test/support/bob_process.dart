// Run as a separate process by keepalive_test.dart: a node with one actor,
// bob, that prints its address and bob's, then runs until it is killed.
import 'dart:io';

import 'package:dactor/dactor.dart';
import 'package:dactor_libp2p/dactor_libp2p.dart';
import 'package:dactor_remote/dactor_remote.dart';

import '../../../dactor_remote/test/support.dart';

Future<void> main(List<String> args) async {
  final [interval, timeout] = [for (final a in args) int.parse(a)];
  final keepAlive = Duration(milliseconds: interval);
  final keepAliveTimeout = Duration(milliseconds: timeout);
  final system = LocalActorSystem(
      ActorSystemConfig(logCollector: const NoOpLogCollector()));
  final transport = Libp2pTransport(await startHost(
      listen: const ['/ip4/127.0.0.1/udp/0/udx'],
      allowLoopback: true,
      keepAlive: keepAlive,
      keepAliveTimeout: keepAliveTimeout));
  final node = RemoteNode(system, transport, codecs: codecs());
  final bob = await system.spawn('bob', () => Agent('bob', []));
  stdout.writeln(transport.addresses.first);
  stdout.writeln(node.uriOf(bob));
  await stdout.flush();
}
