import 'package:meta/meta.dart';

import 'package:dactor/src/actor.dart';
import 'package:dactor/src/actor_ref.dart';

/// The decision made by a supervisor when a child actor fails.
enum SupervisionDecision { resume, restart, stop, escalate }

/// A strategy for supervising child actors.
abstract class SupervisionStrategy {
  /// Whether a restart decision applies to all children (true) or just the failed child (false).
  bool get restartAll => false;

  /// Decides what to do when a child actor fails.
  SupervisionDecision handle(String actorId, Object error, StackTrace stackTrace);
}

/// A supervisor is an actor that supervises other actors.
abstract class Supervisor extends Actor {
  /// The supervision strategy to use.
  SupervisionStrategy get strategy;

  /// Supervises a new child actor.
  Future<ActorRef> supervise<T extends Actor>(
    String id,
    T Function() actorFactory,
  );

  /// Called when a child actor fails.
  @protected
  Future<SupervisionDecision> onChildFailure(
    ActorRef child,
    Object error,
    StackTrace stackTrace,
  );
}
