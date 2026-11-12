// Probe: do two nodes that say nothing to each other stay connected?
// Sends one message each way, then waits [minutes] (default 6) and prints
// every node event and every libp2p warning, with the time.
//
//     dart run tool/idle_probe.dart [minutes]
// ignore_for_file: avoid_print
import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:dactor_libp2p/dactor_libp2p.dart';
import 'package:dactor_remote/dactor_remote.dart';
import 'package:logging/logging.dart';

Future<void> main(List<String> args) async {
  final minutes = args.isEmpty ? 6 : int.parse(args.first);
  final start = DateTime.now();
  String t() {
    final s = DateTime.now().difference(start).inMilliseconds / 1000;
    return '${s.toStringAsFixed(1).padLeft(6)} s';
  }

  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((r) {
    if (r.level < Level.WARNING &&
        !r.message.contains('setReadDeadline') &&
        !r.message.contains('setDeadline')) {
      return;
    }
    final text =
        r.message.length > 300 ? r.message.substring(0, 300) : r.message;
    print('${t()} log ${r.level.name} ${r.loggerName}: $text');
  });

  Future<(RemoteNode, LocalActorSystem)> node(String name) async {
    final host = await startHost(
      listen: const ['/ip4/127.0.0.1/udp/0/udx'],
      allowLoopback: true,
      keepAlive: const Duration(seconds: 5),
      keepAliveTimeout: const Duration(seconds: 15),
    );
    final system = LocalActorSystem(
      ActorSystemConfig(logCollector: const NoOpLogCollector()),
    );
    final remote = RemoteNode(system, Libp2pTransport(host, closeHost: true));
    remote.events.listen((e) => print('${t()} $name: $e'));
    final echo = await system.spawn('echo', () => _Echo());
    remote.expose('echo', echo);
    return (remote, system);
  }

  final (a, sysA) = await node('a');
  final (b, sysB) = await node('b');
  final bFromA = a.resolve(b.uriOf(sysB.getActor('echo')!));
  final aFromB = b.resolve(a.uriOf(sysA.getActor('echo')!));
  print(
      '${t()} ask a->b: ${await bFromA.ask<Object?>(LocalMessage(payload: 1))}');
  print(
      '${t()} ask b->a: ${await aFromB.ask<Object?>(LocalMessage(payload: 2))}');
  print('${t()} idle for $minutes min');
  await Future<void>.delayed(Duration(minutes: minutes));
  print(
      '${t()} ask a->b: ${await bFromA.ask<Object?>(LocalMessage(payload: 3))}');
  await a.close();
  await b.close();
  await sysA.shutdown();
  await sysB.shutdown();
}

class _Echo extends Actor {
  @override
  Future<void> onMessage(dynamic message) async =>
      context.sender?.tell(LocalMessage(payload: message));
}
