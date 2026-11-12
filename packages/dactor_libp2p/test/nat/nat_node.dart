// A dactor node behind a NAT router, for run.sh. It reads the relay's
// address (the Ricochet server) from /shared/server.addr.
//
//   nat_node listen              reserve a relay slot; host bob and a
//                                counter; print ADDR and URI lines. With
//                                PUNCH=0 it does not hole punch (the side
//                                a relayed connection reaches starts one)
//   nat_node check <addr> <uri>  through the relay, hole punching off:
//                                ask, order, 1 MiB, the reverse direction
//   nat_node punch <addr> <uri>  through the relay, then wait for a hole
//                                punch to give a direct connection
//   nat_node watch <addr> <uri>  watch bob, print WATCHING, and report how
//                                long it takes to notice bob's node is gone
//
// LOG=name,name prints those libp2p loggers at every level, for example
// LOG=p2p-holepunch.
//
// Exits non-zero when a check fails.
import 'dart:async';
import 'dart:io';

import 'package:dactor/dactor.dart';
import 'package:dactor_libp2p/dactor_libp2p.dart';
import 'package:dactor_remote/dactor_remote.dart';
import 'package:dart_libp2p/dart_libp2p.dart' show PeerId;
import 'package:logging/logging.dart';

import '../../../dactor_remote/test/support.dart';

const keepAlive = Duration(seconds: 1);
const keepAliveTimeout = Duration(seconds: 3);
final clock = Stopwatch()..start();

void say(String line) => print(
    '${(clock.elapsedMilliseconds / 1000).toStringAsFixed(1).padLeft(6)}s $line');

Never fail(String message) {
  stderr.writeln('nat_node: $message');
  exit(1);
}

Future<void> step(String name, Future<String?> Function() body) async {
  final watch = Stopwatch()..start();
  try {
    final note = await body();
    say('ok   $name (${watch.elapsedMilliseconds} ms)${note == null ? '' : ': $note'}');
  } catch (e) {
    fail('$name: $e');
  }
}

Future<(Libp2pTransport, RemoteNode, LocalActorSystem)> node(
    {required String server,
    required RelayRole relay,
    bool holePunching = false}) async {
  final host = await startHost(
      listen: const ['/ip4/0.0.0.0/udp/0/udx'],
      relay: relay,
      relays: [server],
      holePunching: holePunching,
      // The relay is the only peer that sees this node, so its word alone
      // has to do for the public address a hole punch needs. A node that
      // does not punch keeps libp2p's default, and so never learns its
      // public address: knowing it, libp2p dials it directly when it can,
      // which would take the relay-only checks off the relay.
      observersNeeded: holePunching ? 1 : 4,
      keepAlive: keepAlive,
      keepAliveTimeout: keepAliveTimeout);
  final transport = Libp2pTransport(host, closeHost: true);
  final system = LocalActorSystem(
      ActorSystemConfig(logCollector: const NoOpLogCollector()));
  final remote = RemoteNode(system, transport, codecs: codecs());
  remote.events.listen((e) => say('node event: $e'));
  return (transport, remote, system);
}

/// How [transport] is connected to [node]: the remote addresses.
List<String> connsTo(Libp2pTransport transport, String node) => [
      for (final c
          in transport.host.network.connsToPeer(PeerId.fromString(node)))
        c.remoteMultiaddr.toString()
    ];

Future<void> listen(String server) async {
  final (transport, remote, system) = await node(
      server: server,
      relay: RelayRole.reserve,
      holePunching: Platform.environment['PUNCH'] != '0');
  say('peer ${transport.localNode}');
  final deadline = DateTime.now().add(const Duration(seconds: 60));
  String? circuit;
  while ((circuit = transport.addresses
          .where((a) => a.contains('/p2p-circuit'))
          .firstOrNull) ==
      null) {
    if (DateTime.now().isAfter(deadline)) fail('no relay reservation');
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  final log = <String>[];
  final bob = await system.spawn('bob', () => Agent('bob', log));
  final counter = await system.spawn('counter', () => Counter());
  remote.expose('counter', counter);
  say('addresses ${transport.addresses}');
  // run.sh reads these two lines.
  print('ADDR $circuit');
  print('URI ${remote.uriOf(bob)}');
  var shown = 0;
  Timer.periodic(const Duration(milliseconds: 200), (_) {
    for (; shown < log.length; shown++) {
      final line = log[shown];
      say('bob: ${line.length > 120 ? '${line.substring(0, 120)}…' : line}');
    }
  });
}

Future<void> check(String server, String addr, String uri) async {
  final (transport, remote, system) =
      await node(server: server, relay: RelayRole.client);
  final peer = await transport.addAddress(addr);
  final bob = remote.resolve(uri);
  final log = <String>[];
  final alice = await system.spawn('alice', () => Agent('alice', log));

  await step('ask through the relay', () async {
    final reply = await bob.ask<String>('ping', const Duration(seconds: 30));
    if (reply != 'pong from bob') throw 'got $reply';
    final conns = connsTo(transport, peer);
    if (conns.isEmpty || !conns.every((c) => c.contains('p2p-circuit'))) {
      throw 'not only relayed: $conns';
    }
    return 'over ${conns.join(', ')}';
  });

  await step('5000 messages in order', () async {
    final counter = (await remote.lookup(peer, 'counter')).typed<CounterMsg>();
    for (var i = 1; i <= 5000; i++) {
      counter.tell(Add(i));
    }
    final sum = await counter.call(Get(), timeout: const Duration(seconds: 60));
    if (sum != 12502500) throw 'sum $sum';
    return null;
  });

  await step('1 MiB message through the relay', () async {
    bob.tell('x' * (1 << 20));
    final reply = await bob.ask<String>('ping', const Duration(seconds: 60));
    if (reply != 'pong from bob') throw 'got $reply';
    return null;
  });

  await step('the listener asks back over the same connection', () async {
    await bob.ask<String>(Introduce('alice', alice));
    final reply =
        await bob.ask<String>(('ask', 'alice'), const Duration(seconds: 30));
    if (reply != 'relayed: pong from alice') throw 'got $reply';
    return null;
  });

  await step('still only relayed', () async {
    final conns = connsTo(transport, peer);
    if (!conns.every((c) => c.contains('p2p-circuit'))) throw '$conns';
    return null;
  });
  exit(0);
}

Future<void> punch(String server, String addr, String uri) async {
  final (transport, remote, _) =
      await node(server: server, relay: RelayRole.client, holePunching: true);
  final peer = await transport.addAddress(addr);
  final bob = remote.resolve(uri);
  var downs = 0;
  remote.events.listen((e) {
    if (e is NodeDown) downs++;
  });

  await step('ask through the relay', () async {
    final reply = await bob.ask<String>('ping', const Duration(seconds: 30));
    if (reply != 'pong from bob') throw 'got $reply';
    return 'over ${connsTo(transport, peer).join(', ')}';
  });

  await step('a hole punch gives a direct connection', () async {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline)) {
      final direct = connsTo(transport, peer)
          .where((c) => !c.contains('p2p-circuit'))
          .toList();
      if (direct.isNotEmpty) return 'direct ${direct.join(', ')}';
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw 'none after 30 s; connections: ${connsTo(transport, peer)}';
  });

  await step('dactor traffic moves to the direct connection', () async {
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (
        (transport.routeTo(peer) ?? '/p2p-circuit').contains('/p2p-circuit')) {
      if (DateTime.now().isAfter(deadline)) {
        throw 'still on ${transport.routeTo(peer)}';
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return 'now over ${transport.routeTo(peer)}';
  });

  await step('ask and 5000 messages in order after the move', () async {
    final reply = await bob.ask<String>('ping', const Duration(seconds: 30));
    if (reply != 'pong from bob') throw 'got $reply';
    final counter = (await remote.lookup(peer, 'counter')).typed<CounterMsg>();
    for (var i = 1; i <= 5000; i++) {
      counter.tell(Add(i));
    }
    final sum = await counter.call(Get(), timeout: const Duration(seconds: 60));
    if (sum != 12502500) throw 'sum $sum';
    if (downs > 0) throw 'the node was reported down $downs time(s)';
    return null;
  });
  exit(0);
}

Future<void> watch(String server, String addr, String uri) async {
  final (transport, remote, system) =
      await node(server: server, relay: RelayRole.client);
  await transport.addAddress(addr);
  final bob = remote.resolve(uri);
  final log = <String>[];
  final alice = await system.spawn('alice', () => Agent('alice', log));
  await alice.ask<String>(Introduce('bob', bob), const Duration(seconds: 30));
  await alice.ask<String>(('ask', 'bob'), const Duration(seconds: 30));
  await alice.ask<String>(('watch', 'bob'));
  await Future<void>.delayed(const Duration(milliseconds: 500));
  print('WATCHING');
  final since = Stopwatch()..start();
  while (!log.any((l) => l.endsWith('noconnection'))) {
    if (since.elapsed > const Duration(seconds: 90)) {
      fail('bob\'s node not noticed gone after 90 s');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  say('ok   noticed bob\'s node gone ${since.elapsedMilliseconds} ms after '
      'WATCHING (keep-alive ${keepAlive.inSeconds} s, timeout '
      '${keepAliveTimeout.inSeconds} s)');
  exit(0);
}

Future<void> main(List<String> args) async {
  final loggers = (Platform.environment['LOG'] ?? '')
      .split(',')
      .map((n) => n.trim())
      .where((n) => n.isNotEmpty);
  if (loggers.isNotEmpty) {
    hierarchicalLoggingEnabled = true;
    Logger.root.level = Level.OFF;
    for (final name in loggers) {
      Logger(name).level = Level.ALL;
    }
    Logger.root.onRecord.listen((r) => say('[${r.loggerName}] ${r.message}'));
  }
  final server = File('/shared/server.addr').readAsStringSync().trim();
  say('relay $server');
  switch (args) {
    case ['listen']:
      await listen(server);
    case ['check', final addr, final uri]:
      await check(server, addr, uri);
    case ['punch', final addr, final uri]:
      await punch(server, addr, uri);
    case ['watch', final addr, final uri]:
      await watch(server, addr, uri);
    default:
      fail('usage: nat_node listen | check|punch|watch <addr> <uri>');
  }
}
