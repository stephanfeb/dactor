import 'dart:async';

import 'package:meta/meta.dart';

import 'package:dactor/src/actor.dart';
import 'package:dactor/src/actor_ref.dart';

/// Implemented by behaviours that keep their state as one value, which lets
/// the system read it, replace it, and hand it to a new version of the code.
abstract interface class StatefulBehaviour {
  /// The current state.
  Object? get behaviourState;
  set behaviourState(Object? value);

  /// The version of the code that produced [behaviourState].
  int get behaviourVersion;
}

/// State passed from one version of a behaviour to the next during
/// [Sys.upgrade].
typedef BehaviourHandoff = ({int version, Object? state});

/// The side of an actor's context that behaviours in this package use and
/// application code does not.
@internal
abstract interface class BehaviourContext {
  /// The state the previous incarnation handed over, if this incarnation was
  /// started by an upgrade. Returns it once.
  BehaviourHandoff? takeHandoff();

  /// Puts [message] in front of every user message waiting for this actor.
  void deliverFirst(Object? message);
}

/// A snapshot of one actor, from [Sys.statistics].
class ActorStatistics {
  /// Messages handed to the actor since it was spawned.
  final int messagesProcessed;

  /// Messages waiting in its mailbox.
  final int mailboxSize;

  /// How many times it has been restarted.
  final int restarts;

  /// Whether [Sys.suspend] is in effect.
  final bool suspended;

  /// Whether a handler (or `preStart`) is running right now.
  final bool busy;

  const ActorStatistics({
    required this.messagesProcessed,
    required this.mailboxSize,
    required this.restarts,
    required this.suspended,
    required this.busy,
  });

  @override
  String toString() => 'ActorStatistics(processed: $messagesProcessed, '
      'mailbox: $mailboxSize, restarts: $restarts, suspended: $suspended, '
      'busy: $busy)';
}

/// Inspection and control of running actors, for debugging and operations.
/// Obtained from `LocalActorSystem.sys`.
///
/// Requests that touch an actor's state travel through its mailbox, ahead of
/// ordinary messages, so they never run in the middle of a handler.
abstract interface class Sys {
  /// The state of [actor]: the state value of a behaviour such as
  /// `GenServer`, or the [Actor] object itself for a plain actor.
  Future<Object?> getState(ActorRef actor, {Duration? timeout});

  /// Replaces the state of a behaviour with `update(current)` and returns
  /// the new state. Fails with [UnsupportedError] for a plain actor.
  Future<Object?> replaceState(
      ActorRef actor, Object? Function(Object? current) update,
      {Duration? timeout});

  /// Stops delivering ordinary messages to [actor]. They queue up until
  /// [resume]. System requests are still answered.
  void suspend(ActorRef actor);

  /// Undoes [suspend].
  void resume(ActorRef actor);

  /// Turns logging of every message [actor] receives on or off. Records go
  /// to the system's log collector at debug level.
  void trace(ActorRef actor, bool enabled);

  ActorStatistics statistics(ActorRef actor);

  /// Replaces the code of [actor] and keeps its state.
  ///
  /// The actor finishes the handler it is in and is restarted from
  /// [newFactory], keeping its `ActorRef` and mailbox. If both the old and
  /// the new actor are behaviours, the new one receives the old state through
  /// its `codeChange` instead of running `init`. Later restarts use
  /// [newFactory] too.
  Future<void> upgrade(ActorRef actor, Actor Function() newFactory);
}
