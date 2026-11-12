@Timeout(Duration(seconds: 120))
library;

import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:dactor_libp2p/dactor_libp2p.dart';
import 'package:dactor_remote/dactor_remote.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Discovery: a node that was never given an address for another one
/// reaches it anyway, because a reference, the text of one, or a process
/// group brought the address with it.
///
/// The phone listens on nothing and is reached only through a relay, as
/// behind a NAT. The server knows the phone's relay address. The newcomer
/// knows the server's address at most, and nothing about the phone.
void main() {
  late Libp2pTransport relay;
  late TestNode server, phone, newcomer;
  late Libp2pTransport phoneTransport;
  final log = <String>[];
  final closing = <Future<void> Function()>[];

  Future<Libp2pTransport> transport(
          {bool listen = true,
          List<String> relays = const [],
          Future<List<String>> Function(String)? resolve}) async =>
      Libp2pTransport(
          await startHost(
              listen: listen ? const ['/ip4/127.0.0.1/udp/0/udx'] : const [],
              relay: relays.isEmpty ? RelayRole.client : RelayRole.reserve,
              relays: relays,
              allowLoopback: true),
          closeHost: true,
          dialTimeout: const Duration(seconds: 3),
          resolve: resolve);

  TestNode node(Libp2pTransport transport) {
    final system = LocalActorSystem(
        ActorSystemConfig(logCollector: const NoOpLogCollector()));
    final node =
        TestNode(system, RemoteNode(system, transport, codecs: codecs()));
    closing.add(node.close);
    return node;
  }

  setUp(() async {
    log.clear();
    relay = Libp2pTransport(
        await startHost(
            listen: const ['/ip4/127.0.0.1/udp/0/udx'],
            relay: RelayRole.server,
            allowLoopback: true),
        closeHost: true);
    closing.add(relay.close);
    phoneTransport =
        await transport(listen: false, relays: [relay.addresses.first]);
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (!phoneTransport.localAddresses.any((a) => a.contains('circuit'))) {
      if (DateTime.now().isAfter(deadline)) fail('no relay reservation');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    phone = node(phoneTransport);
    final serverTransport = await transport();
    await serverTransport.addAddresses(phoneTransport.localAddresses);
    server = node(serverTransport);
    phone.remote.expose(
        'bob', await phone.system.spawn('bob', () => Agent('bob', log)));
  });

  tearDown(() async {
    for (final close in closing.reversed) {
      await close();
    }
    closing.clear();
  });

  test('a reference handed over brings its node\'s addresses', () async {
    newcomer = node(await transport());
    // The server knows the newcomer, which knows nothing about the phone.
    await (server.remote.transport as Libp2pTransport)
        .addAddresses((newcomer.remote.transport as Libp2pTransport).addresses);
    expect(newcomer.remote.addressesOf(phone.id), isEmpty);

    final received = Completer<ActorRef>();
    newcomer.remote.serve('inbox', (from, data, refs) {
      received.complete(refs.single);
    });
    final bob = await server.remote.lookup(phone.id, 'bob');
    server.remote.sendToService(newcomer.id, 'inbox', null, refs: [bob]);

    final bobHere = await received.future.timeout(const Duration(seconds: 10));
    expect(newcomer.remote.addressesOf(phone.id),
        everyElement(contains('/p2p-circuit/p2p/${phone.id}')));
    expect(await bobHere.ask<String>('ping'), 'pong from bob');
  });

  test('the text of a reference is enough to reach it', () async {
    final bob = phone.system.getActor('bob')!;
    final uri = phone.remote.uriOf(bob);
    expect(uri, contains('&addr='));
    expect(phone.remote.uriOf(bob, withAddresses: false),
        isNot(contains('addr=')));

    // A node that knows no one at all.
    newcomer = node(await transport());
    final bobHere = newcomer.remote.resolve(uri);
    expect(await bobHere.ask<String>('ping'), 'pong from bob');
  });

  test('a process group passes on the addresses of its nodes', () async {
    newcomer = node(await transport());
    final scope = {
      for (final n in [server, phone, newcomer])
        n: ProcessGroups(n.remote, retry: const Duration(milliseconds: 500))
    };
    for (final groups in scope.values) {
      closing.add(groups.close);
    }
    scope[phone]!.join('workers', phone.system.getActor('bob')!);
    // The server knows the phone; the newcomer knows only the server.
    scope[server]!.connect(phone.id);
    await (newcomer.remote.transport as Libp2pTransport)
        .addAddresses((server.remote.transport as Libp2pTransport).addresses);
    scope[newcomer]!.connect(server.id);

    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (scope[newcomer]!.members('workers').isEmpty) {
      if (DateTime.now().isAfter(deadline)) fail('the newcomer never saw bob');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(scope[newcomer]!.nodes, {server.id, phone.id});
    final bob = scope[newcomer]!.members('workers').single;
    expect(await bob.ask<String>('ping'), 'pong from bob');
  });

  test('a resolver is asked for a node no one gave an address for', () async {
    final asked = <String>[];
    newcomer = node(await transport(resolve: (node) async {
      asked.add(node);
      return node == phone.id ? phoneTransport.localAddresses : const [];
    }));
    final bob = await newcomer.remote.lookup(phone.id, 'bob');
    expect(await bob.ask<String>('ping'), 'pong from bob');
    expect(asked, [phone.id]);
  });

  test('addresses for another node than the one named are ignored', () async {
    final t = await transport();
    closing.add(t.close);
    t.learn(phone.id, ['/ip4/127.0.0.1/udp/1/udx/p2p/${server.id}']);
    expect(t.addressesOf(phone.id), isEmpty);
    t.learn(phone.id, phoneTransport.localAddresses);
    expect(t.addressesOf(phone.id), phoneTransport.localAddresses);
  });
}
