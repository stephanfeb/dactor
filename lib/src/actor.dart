import 'dart:async';

import 'package:meta/meta.dart';

import 'package:dactor/src/actor_ref.dart';
import 'package:dactor/src/actor_system.dart';
import 'package:dactor/src/exit_reason.dart';
import 'package:dactor/src/timer_scheduler.dart';

/// The context of an actor, providing information about its environment and
/// allowing it to interact with the actor system.
abstract class ActorContext {
  /// A reference to the actor itself.
  ActorRef get self;

  /// A reference to the actor system.
  ActorSystem get system;

  /// The sender of the current message.
  ActorRef? get sender;

  /// The timer scheduler for this actor.
  ///
  /// Use this to schedule messages to be sent to this actor at specific times
  /// or intervals. All timers are automatically cancelled when the actor is
  /// stopped or restarted.
  TimerScheduler get timers;

  /// Spawns a new top-level actor.
  ///
  /// The new actor is *not* supervised by this one, whatever its [id] looks
  /// like. To create a supervised child, extend [SupervisorActor] and call
  /// `supervise`.
  Future<ActorRef> spawn<T extends Actor>(String id, T Function() actorFactory);

  /// Watches an actor for termination.
  void watch(ActorRef actor);

  /// Links this actor with [other], in both directions.
  ///
  /// When either one ends, the other is told. An actor that traps exits (see
  /// [trapExits]) receives an [ExitSignal] message. One that does not ignores
  /// a normal exit and fails with [LinkedActorExited] on any other, which its
  /// supervisor then handles like any failure.
  ///
  /// A link belongs to the two incarnations that made it. A restart of either
  /// actor counts as that incarnation ending: the other side is signalled and
  /// the link is gone. Link again in `preStart` to keep the pairing.
  ///
  /// Linking to an actor that is already dead signals [NoProcExit] at once.
  void link(ActorRef other);

  /// Removes the link with [other], if there is one.
  void unlink(ActorRef other);

  /// Whether exit signals from linked actors arrive as [ExitSignal] messages
  /// instead of bringing this actor down. False by default, and again after
  /// every restart; set it in `preStart`.
  bool get trapExits;
  set trapExits(bool value);

  /// Waits, inside a handler, for the next message of type [T] that passes
  /// [where], and returns it. Other messages stay in the mailbox, in order,
  /// and are handled as usual once the current handler has returned.
  ///
  /// Fails with a [TimeoutException] if nothing matches within [timeout].
  ///
  /// Use it sparingly. Every call scans the whole mailbox, so on an actor
  /// with a backlog it is slow, and an actor waiting here handles nothing
  /// else.
  Future<T> receive<T>({bool Function(T message)? where, Duration? timeout});

  /// Restarts [child] in place.
  ///
  /// The child's [ActorRef], mailbox (including pending messages), watchers
  /// and event-bus subscriptions are preserved. Only the [Actor] instance is
  /// replaced: `postStop` runs on the old instance, its timers are cancelled,
  /// and `preStart` runs on the new instance before it receives any message.
  Future<void> restart(ActorRef child);

  /// Publishes an event to the event bus.
  ///
  /// The event will be delivered to all actors subscribed to the event type.
  void publish<T>(T event) => system.eventBus.publish<T>(event);

  /// Subscribes this actor to events of the specified type.
  ///
  /// The actor will receive all events of type [T] via its onMessage method.
  void subscribe<T>() => system.eventBus.subscribe<T>(self);

  /// Unsubscribes this actor from events of the specified type.
  void unsubscribe<T>() => system.eventBus.unsubscribe<T>(self);
}

/// An abstract class representing an actor.
///
/// Actors are the fundamental units of computation in the actor model. They
/// encapsulate state and behavior, and communicate with each other by sending
abstract class Actor {
  /// The context of the actor: its own reference, the sender of the message
  /// being handled, timers, and the rest of what an actor can reach.
  ///
  /// Set by the system before `preStart`. Not available in the constructor.
  late ActorContext context;

  /// Called when a message is received.
  @protected
  Future<void> onMessage(dynamic message);

  /// Called when the actor is started.
  @protected
  FutureOr<void> preStart() {}

  /// Called when the actor is stopped.
  @protected
  void postStop() {}

  /// Called when an error occurs.
  @protected
  void onError(Object error, StackTrace stackTrace) {}
}
