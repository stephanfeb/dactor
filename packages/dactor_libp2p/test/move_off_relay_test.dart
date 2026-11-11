@Timeout(Duration(seconds: 90))
library;

import 'package:dactor/dactor.dart';
import 'package:dactor_libp2p/dactor_libp2p.dart';
import 'package:dactor_remote/dactor_remote.dart';
import 'package:dart_libp2p/dart_libp2p.dart' show Context, PeerId;
import 'package:test/test.dart';

import 'support.dart';

/// When a direct connection appears while frames go over a relay (what a
/// hole punch does), frames move to it without a gap, out-of-order frame
/// or node-down report, in both directions.
void main() {
  test('frames move from a relayed to a direct connection mid-stream',
      () async {
    final relay = Libp2pTransport(
        await startHost(
            listen: const ['/ip4/127.0.0.1/udp/0/udx'],
            relay: RelayRole.server,
            allowLoopback: true),
        closeHost: true);
    addTearDown(relay.close);

    // The phone has a relay slot and also a direct address, which it does
    // not advertise, so the server cannot go direct until told.
    final phoneTransport = Libp2pTransport(
        await startHost(
            listen: const ['/ip4/127.0.0.1/udp/0/udx'],
            relay: RelayRole.reserve,
            relays: [relay.addresses.first],
            announce: (address) => address.contains('/p2p-circuit')),
        closeHost: true);
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (!phoneTransport.addresses.any((a) => a.contains('p2p-circuit'))) {
      if (DateTime.now().isAfter(deadline)) fail('no relay reservation');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final serverTransport = Libp2pTransport(
        await startHost(
            listen: const ['/ip4/127.0.0.1/udp/0/udx'], allowLoopback: true),
        closeHost: true);
    await serverTransport.addAddresses(
        phoneTransport.addresses.where((a) => a.contains('p2p-circuit')));

    final cluster = LoopbackCluster();
    final server = await cluster.add(serverTransport);
    final phone = await cluster.add(phoneTransport);
    addTearDown(() async {
      await server.close();
      await phone.close();
    });
    final events = <NodeEvent>[];
    server.remote.events.listen(events.add);
    phone.remote.events.listen(events.add);

    phone.remote.expose(
        'counter', await phone.system.spawn('counter', () => Counter()));
    final counter =
        (await server.remote.lookup(phone.id, 'counter')).typed<CounterMsg>();
    // The phone answers on its own stream to the server; make it exist.
    expect(await counter.call(Get()), 0);
    expect(serverTransport.routeTo(phone.id), contains('p2p-circuit'));
    expect(phoneTransport.routeTo(server.id), contains('p2p-circuit'));

    var expected = 0;
    for (var i = 1; i <= 2500; i++) {
      counter.tell(Add(i));
      expected += i;
    }
    // A direct connection appears, as a hole punch would make one.
    final direct = phoneTransport.host.network.listenAddresses
        .firstWhere((a) => !a.toString().contains('p2p-circuit'));
    final phonePeer = PeerId.fromString(phone.id);
    await serverTransport.host.peerStore.addrBook
        .addAddrs(phonePeer, [direct], const Duration(hours: 1));
    // connect() is satisfied by the relayed connection; the hole puncher
    // forces a direct dial like this.
    await serverTransport.host.network
        .dialPeer(Context().withForceDirectDial('test'), phonePeer);
    for (var i = 2501; i <= 5000; i++) {
      counter.tell(Add(i));
      expected += i;
      if (i % 500 == 0) await Future<void>.delayed(Duration.zero);
    }
    expect(await counter.call(Get()), expected);

    // Both directions now go direct, and nobody saw the node go down.
    final until = DateTime.now().add(const Duration(seconds: 10));
    while ((serverTransport.routeTo(phone.id) ?? 'p2p-circuit')
            .contains('p2p-circuit') ||
        (phoneTransport.routeTo(server.id) ?? 'p2p-circuit')
            .contains('p2p-circuit')) {
      if (DateTime.now().isAfter(until)) {
        fail('still relayed: server→phone ${serverTransport.routeTo(phone.id)}'
            ', phone→server ${phoneTransport.routeTo(server.id)}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(await counter.call(Get()), expected);
    expect(events.whereType<NodeDown>(), isEmpty);
  });
}
