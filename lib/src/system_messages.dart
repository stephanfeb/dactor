import 'package:dactor/src/actor_ref.dart';
import 'package:dactor/src/exit_reason.dart';

/// Tells a watcher that the actor it watched has ended. Only the runtime
/// delivers these; one told in the ordinary way is dropped.
class Terminated {
  final ActorRef actor;

  /// Why the actor ended.
  final ExitReason reason;

  Terminated(this.actor, {this.reason = const NormalExit()});

  @override
  String toString() => 'Terminated(${actor.id}, $reason)';
}

/// A message that could not be delivered.
class DeadLetter {
  /// The message, as it was told.
  final Object? message;

  /// Who told it, or null if it came from outside any actor.
  final ActorRef? sender;
  final ActorRef recipient;
  final DateTime timestamp;

  DeadLetter(this.message, this.sender, this.recipient)
      : timestamp = DateTime.now();

  @override
  String toString() => 'DeadLetter($message to ${recipient.id})';
}
