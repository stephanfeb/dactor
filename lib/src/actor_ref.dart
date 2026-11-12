import 'exit_reason.dart';

/// A reference to an actor, which can be used to send messages to it.
///
/// An ActorRef is a lightweight, serializable handle to an actor. It is the
/// only way to communicate with an actor.
abstract class ActorRef {
  /// The unique identifier of the actor.
  String get id;

  /// Whether the actor is still alive.
  bool get isAlive;

  /// Sends [message] to the actor. Any value will do; the actor's
  /// `onMessage` receives it as it is.
  ///
  /// Fire and forget: nothing says whether it arrived. The sender the actor
  /// sees as `context.sender` is the actor whose code is calling `tell`, or
  /// null outside any actor; it cannot be chosen. To pass a message on with
  /// its original sender, use `ActorContext.forward`.
  ///
  /// A `Terminated` or `ExitSignal` told this way is dropped: only the
  /// runtime sends those.
  void tell(Object? message);

  /// Sends [message] and waits for the actor's answer, which must be a [T].
  ///
  /// The actor answers by telling `context.sender`. Fails with a
  /// `TimeoutException` if no answer comes within [timeout], or the system's
  /// default when it is null.
  Future<T> ask<T>(Object? message, [Duration? timeout]);

  /// Registers the current actor to watch the target actor.
  ///
  /// When the target actor is terminated, a [Terminated] message is sent to the
  /// watcher.
  void watch(ActorRef watcher);

  /// Stops watching: [watcher] is no longer told when this actor ends.
  ///
  /// Removes every watch [watcher] has on this actor. A [Terminated] sent
  /// before this call may still be in [watcher]'s mailbox; from inside an
  /// actor, `context.unwatch` removes that too.
  void unwatch(ActorRef watcher);
}

/// A reference to an actor that lives outside this system, on another node.
///
/// Implemented by transports. It lets a local actor link with the actor
/// behind the reference: the system records the link on its side and tells
/// the reference, which carries it to the other node.
abstract interface class ForeignActorRef implements ActorRef {
  /// [local] has linked with the actor behind this reference.
  void linkFrom(ActorRef local);

  /// [local] has removed its link.
  void unlinkFrom(ActorRef local);

  /// [local], which was linked with the actor behind this reference, ended.
  void linkedExit(ActorRef local, ExitReason reason);
}
