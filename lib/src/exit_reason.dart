import 'package:dactor/src/actor_ref.dart';

/// Why an actor, or one incarnation of it, ended.
///
/// Delivered to watchers in [Terminated] and to linked actors in
/// [ExitSignal]. Every reason except [NormalExit] is abnormal: it brings
/// down linked actors that do not trap exits.
sealed class ExitReason {
  const ExitReason();

  /// True only for [NormalExit].
  bool get isNormal => false;
}

/// The actor was stopped on request and finished cleanly.
final class NormalExit extends ExitReason {
  const NormalExit();

  @override
  bool get isNormal => true;

  @override
  String toString() => 'normal';
}

/// The actor was stopped by its supervisor or parent, or because the system
/// shut down.
final class ShutdownExit extends ExitReason {
  const ShutdownExit();

  @override
  String toString() => 'shutdown';
}

/// The actor was killed: by [ActorSystem.kill], or because it did not stop
/// within the stop timeout.
final class KilledExit extends ExitReason {
  const KilledExit();

  @override
  String toString() => 'killed';
}

/// The actor failed: a handler threw, an error escaped its zone, or
/// `preStart` threw.
final class ErrorExit extends ExitReason {
  final Object error;
  final StackTrace stackTrace;

  const ErrorExit(this.error, this.stackTrace);

  @override
  String toString() => 'error: $error';
}

/// The actor did not exist. Sent in answer to a link with a dead actor.
final class NoProcExit extends ExitReason {
  const NoProcExit();

  @override
  String toString() => 'noproc';
}

/// The connection to the node the actor lives on was lost. The actor itself
/// may well be alive; from here there is no telling.
final class NoConnectionExit extends ExitReason {
  const NoConnectionExit();

  @override
  String toString() => 'noconnection';
}

/// Delivered as a message to an actor that traps exits when an actor it is
/// linked to ends.
///
/// An actor that does not trap exits never sees this. It ignores a normal
/// exit and fails with [LinkedActorExited] on any other.
class ExitSignal {
  /// The linked actor that ended.
  final ActorRef from;
  final ExitReason reason;

  const ExitSignal(this.from, this.reason);

  @override
  String toString() => 'ExitSignal(${from.id}, $reason)';
}

/// The error an actor fails with when an actor it is linked to ends
/// abnormally and it does not trap exits. Supervision deciders see this.
class LinkedActorExited implements Exception {
  final ActorRef from;
  final ExitReason reason;

  const LinkedActorExited(this.from, this.reason);

  @override
  String toString() => 'Linked actor ${from.id} exited: $reason';
}
