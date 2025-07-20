import 'package:dactor/src/routing/routing_logic.dart';

class Pool {
  final int workerCount;
  final RoutingLogic logic;

  Pool({required this.workerCount, RoutingLogic? logic})
      : logic = logic ?? RoundRobinRoutingLogic();
}
