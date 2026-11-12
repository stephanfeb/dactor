import 'exit_reason.dart';
import 'message.dart';

/// A reference to an actor, which can be used to send messages to it.
///
/// An ActorRef is a lightweight, serializable handle to an actor. It is the
/// only way to communicate with an actor.
abstract class ActorRef {
  /// The unique identifier of the actor.
  String get id;

  /// Whether the actor is still alive.
  bool get isAlive;

  /// Sends a message to the actor.
  ///
  /// This is a fire-and-forget operation. The message is sent asynchronously
  /// and there is no guarantee of delivery.
  void tell(Message message, {ActorRef? sender});

  /// Sends a message to the actor and returns a future that completes with the
  /// response.
  ///
  /// This is a request-response operation. The message is sent asynchronously
  /// and the future completes with the response from the actor.
  ///
  /// **Important**: For ask operations, response messages should extend [LocalMessage]
  /// and override the `payload` getter to return `this` (the response object itself).
  /// This ensures proper type casting and response handling.
  ///
  /// Example:
  /// ```dart
  /// class MyResponse extends LocalMessage {
  ///   final String result;
  ///   MyResponse(this.result) : super(payload: null);
  ///   @override
  ///   dynamic get payload => this;
  /// }
  /// ```
  ///
  /// The request message can be either a [Message] or [LocalMessage]. If a regular
  /// [Message] is provided, it will be automatically wrapped in a [LocalMessage].
  ///
  /// If [timeout] is null, the default timeout from the actor system configuration is used.
  Future<T> ask<T>(Message message, [Duration? timeout]);

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
