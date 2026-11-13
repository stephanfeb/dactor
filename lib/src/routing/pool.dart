import 'package:dactor/src/routing/routing_logic.dart';

/// Asks `spawn` for a pool: [workerCount] identical workers behind one
/// `ActorRef`, with [logic] choosing the worker for each message.
class Pool {
  /// How many workers the pool starts.
  final int workerCount;

  /// Chooses a worker for each message. Round robin unless given.
  final RoutingLogic logic;

  Pool({required this.workerCount, RoutingLogic? logic})
      : logic = logic ?? RoundRobinRoutingLogic();
}
