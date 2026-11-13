/// Chooses which worker of a pool gets each message.
abstract class RoutingLogic {
  int _next = 0;

  /// Returns the index, from 0 to [routeeCount] - 1, of the worker that gets
  /// [message]. By default the workers take turns.
  int select(int routeeCount, Object? message) {
    final index = _next % routeeCount;
    _next = index + 1;
    return index;
  }
}

/// The workers take turns.
class RoundRobinRoutingLogic extends RoutingLogic {}
