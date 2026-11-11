import 'package:dactor/dactor.dart';
import 'package:dactor_libp2p/dactor_libp2p.dart';
import 'package:dactor_remote/dactor_remote.dart';

import '../../dactor_remote/test/support.dart';

export '../../dactor_remote/test/support.dart';

/// Nodes on loopback that know each other's direct addresses, as a
/// discovery mechanism would arrange.
///
/// A dial to a node that is gone fails only after [dialTimeout]: over UDP
/// nothing refuses it. Asks time out after 5 s, so the dial must give up
/// sooner for an ask to fail with `NodeUnreachable`.
class LoopbackCluster {
  final Duration dialTimeout;
  LoopbackCluster({this.dialTimeout = const Duration(seconds: 2)});

  final _transports = <Libp2pTransport>[];

  Future<TestNode> newNode() async {
    final host = await startHost(
        listen: const ['/ip4/127.0.0.1/udp/0/udx'], allowLoopback: true);
    return add(
        Libp2pTransport(host, closeHost: true, dialTimeout: dialTimeout));
  }

  Future<TestNode> add(Libp2pTransport transport) async {
    for (final other in _transports) {
      if (transport.host.addrs.isNotEmpty) {
        await other.addAddresses(transport.addresses);
      }
      if (other.host.addrs.isNotEmpty) {
        await transport.addAddresses(other.addresses);
      }
    }
    _transports.add(transport);
    final system = LocalActorSystem(
        ActorSystemConfig(logCollector: const NoOpLogCollector()));
    return TestNode(system, RemoteNode(system, transport, codecs: codecs()));
  }
}
