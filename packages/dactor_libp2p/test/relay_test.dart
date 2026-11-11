@Timeout(Duration(seconds: 90))
library;

import 'package:dactor/dactor.dart';
import 'package:dactor_libp2p/dactor_libp2p.dart';
import 'package:dart_libp2p/dart_libp2p.dart' show PeerId;
import 'package:test/test.dart';

import 'support.dart';

/// A node that cannot be dialled directly (standing in for a phone behind
/// a NAT; here it simply listens on nothing) is reached through a relay,
/// in both directions, and the loss of the relay is noticed on both sides.
void main() {
  late Libp2pTransport relay;
  late TestNode server;
  late TestNode phone;
  late Libp2pTransport serverTransport;
  late Libp2pTransport phoneTransport;
  final log = <String>[];

  setUp(() async {
    log.clear();
    // The relay runs no actors; it only needs a host.
    relay = Libp2pTransport(
        await startHost(
            listen: const ['/ip4/127.0.0.1/udp/0/udx'],
            relay: RelayRole.server,
            allowLoopback: true),
        closeHost: true);
    final relayAddress = relay.addresses.first;

    phoneTransport = Libp2pTransport(
        await startHost(
            listen: const [],
            relay: RelayRole.reserve,
            relays: [relayAddress],
            allowLoopback: true),
        closeHost: true,
        dialTimeout: const Duration(seconds: 3));
    // The reservation takes a few seconds (libp2p's AutoRelay boot delay).
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (!phoneTransport.addresses.any((a) => a.contains('p2p-circuit'))) {
      if (DateTime.now().isAfter(deadline)) fail('no relay reservation');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    serverTransport = Libp2pTransport(
        await startHost(
            listen: const ['/ip4/127.0.0.1/udp/0/udx'], allowLoopback: true),
        closeHost: true,
        dialTimeout: const Duration(seconds: 3));
    // The server learns the phone's relay address, from a QR code, a DHT,
    // a message from someone else. The phone learns nothing about the
    // server: it is reached over the connection the server opens.
    await serverTransport.addAddresses(phoneTransport.addresses);
    expect(phoneTransport.addresses,
        everyElement(contains('/p2p-circuit/p2p/${phoneTransport.localNode}')));

    final cluster = LoopbackCluster();
    server = await cluster.add(serverTransport);
    phone = await cluster.add(phoneTransport);
    addTearDown(() async {
      await server.close();
      await phone.close();
      await relay.close();
    });
  });

  test('the server reaches an actor on the phone, and it answers', () async {
    final alice = await server.system.spawn('alice', () => Agent('alice', log));
    phone.remote.expose(
        'bob', await phone.system.spawn('bob', () => Agent('bob', log)));
    final bob = await server.remote.lookup(phone.id, 'bob');

    expect(
        await bob.ask<String>(LocalMessage(payload: 'ping')), 'pong from bob');
    await alice.ask<String>(LocalMessage(payload: Introduce('bob', bob)));
    expect(await alice.ask<String>(LocalMessage(payload: ('ask', 'bob'))),
        'relayed: pong from bob');

    // Every connection between them goes through the relay.
    final conns = serverTransport.host.network
        .connsToPeer(PeerId.fromString(phoneTransport.localNode));
    expect(conns, isNotEmpty);
    expect(conns.map((c) => c.remoteMultiaddr.toString()),
        everyElement(contains('p2p-circuit')));
  });

  test('the phone reaches back to the server over the relayed connection',
      () async {
    server.remote.expose(
        'alice', await server.system.spawn('alice', () => Agent('alice', log)));
    final carol = await phone.system.spawn('carol', () => Agent('carol', log));
    phone.remote.expose('carol', carol);

    // The phone has no address for the server. Once the server has
    // connected (here, by looking carol up), the phone reaches it over that
    // connection, through the relay.
    await server.remote.lookup(phone.id, 'carol');
    final alice = await phone.remote.lookup(server.id, 'alice');
    await carol.ask<String>(LocalMessage(payload: Introduce('alice', alice)));
    expect(await carol.ask<String>(LocalMessage(payload: ('ask', 'alice'))),
        'relayed: pong from alice');
  });

  test('losing the relay is noticed on both sides', () async {
    final alice = await server.system.spawn('alice', () => Agent('alice', log));
    final carol = await phone.system.spawn('carol', () => Agent('carol', log));
    server.remote.expose('alice', alice);
    phone.remote.expose(
        'bob', await phone.system.spawn('bob', () => Agent('bob', log)));

    final bob = await server.remote.lookup(phone.id, 'bob');
    await alice.ask<String>(LocalMessage(payload: Introduce('bob', bob)));
    await alice.ask<String>(LocalMessage(payload: ('watch', 'bob')));
    final aliceFromPhone = await phone.remote.lookup(server.id, 'alice');
    await carol
        .ask<String>(LocalMessage(payload: Introduce('alice', aliceFromPhone)));
    await carol.ask<String>(LocalMessage(payload: ('watch', 'alice')));
    await Future<void>.delayed(const Duration(milliseconds: 200));

    final watch = Stopwatch()..start();
    await relay.close();
    while (log.where((l) => l.endsWith('noconnection')).length < 2 &&
        watch.elapsed < const Duration(seconds: 30)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(log, contains('alice saw ${bob.id} terminated: noconnection'));
    expect(log,
        contains('carol saw ${aliceFromPhone.id} terminated: noconnection'));
    printOnFailure('noticed after ${watch.elapsedMilliseconds} ms');
  });
}
