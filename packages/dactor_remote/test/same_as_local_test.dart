import 'package:dactor/dactor.dart';
import 'package:dactor_remote/dactor_remote.dart';
import 'package:dactor_remote/tcp.dart';

import 'support.dart';
import 'support/transport_scenarios.dart';

Future<TestNode> _tcpNode() async {
  final system = LocalActorSystem(
      ActorSystemConfig(logCollector: const NoOpLogCollector()));
  return TestNode(
      system, RemoteNode(system, await TcpTransport.bind(), codecs: codecs()));
}

void main() {
  final network = InMemoryNetwork();
  var n = 0;
  sameAsLocalScenarios('sameSystem', null);
  sameAsLocalScenarios(
      'inMemoryNetwork', () async => join(network, 'node${n++}'));
  sameAsLocalScenarios('tcp', _tcpNode);
  transportScenarios('tcp', _tcpNode);
}
