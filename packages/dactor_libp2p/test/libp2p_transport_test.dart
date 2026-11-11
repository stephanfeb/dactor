@Timeout(Duration(seconds: 60))
library;

import 'package:test/test.dart';

import '../../dactor_remote/test/support/transport_scenarios.dart';
import 'support.dart';

/// The scenarios the in-memory and TCP transports pass, over libp2p
/// (UDX, Noise, Yamux) on loopback.
void main() {
  final cluster = LoopbackCluster();
  sameAsLocalScenarios('libp2p', cluster.newNode,
      settleTime: const Duration(milliseconds: 150));
  transportScenarios('libp2p', cluster.newNode,
      noticeWithin: const Duration(seconds: 1));
}
