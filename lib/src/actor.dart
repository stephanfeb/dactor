import 'dart:async';

import 'package:meta/meta.dart';

import 'package:dactor/src/actor_ref.dart';
import 'package:dactor/src/actor_system.dart';
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
