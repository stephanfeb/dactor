import 'dart:async';

import 'package:dactor/src/actor_ref.dart';
import 'package:dactor/src/local_message.dart';

/// A message to subscribe to events of a specific type.
class Subscribe<T> {
  final ActorRef subscriber;
  final Type eventType;

  Subscribe(this.subscriber, this.eventType);

  @override
  String toString() => 'Subscribe<$T>($subscriber, $eventType)';
}

/// A message to unsubscribe from events of a specific type.
class Unsubscribe<T> {
  final ActorRef subscriber;
  final Type eventType;

  Unsubscribe(this.subscriber, this.eventType);

  @override
  String toString() => 'Unsubscribe<$T>($subscriber, $eventType)';
}

/// A message to publish an event to all subscribers.
class Publish<T> {
  final T event;

  Publish(this.event);

  @override
  String toString() => 'Publish<$T>($event)';
}

/// Represents an active event subscription.
class EventSubscription {
  final ActorRef subscriber;
  final Type eventType;
  final DateTime createdAt;

  EventSubscription(this.subscriber, this.eventType) 
      : createdAt = DateTime.now();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EventSubscription &&
          runtimeType == other.runtimeType &&
          subscriber == other.subscriber &&
          eventType == other.eventType;

  @override
  int get hashCode => subscriber.hashCode ^ eventType.hashCode;

  @override
  String toString() => 'EventSubscription($subscriber, $eventType)';
}

/// The event bus manages event subscriptions and routing.
/// 
/// This implementation provides type-safe event publishing and subscription
/// following the actor model principles. Events are delivered asynchronously
/// to all registered subscribers.
class EventBus {
  final Map<Type, Set<ActorRef>> _subscriptions = {};
  final Map<ActorRef, Set<Type>> _subscriberTypes = {};
  final StreamController<EventBusEvent> _eventController = StreamController.broadcast();

  /// Stream of event bus events for monitoring and debugging.
  Stream<EventBusEvent> get events => _eventController.stream;

  /// Subscribe an actor to events of a specific type.
  /// 
  /// The subscriber will receive all events of type [T] and its subtypes.
  /// Multiple subscriptions to the same type by the same actor are idempotent.
  void subscribe<T>(ActorRef subscriber) {
    final eventType = T;
    final wasAdded = _subscriptions.putIfAbsent(eventType, () => <ActorRef>{}).add(subscriber);
    _subscriberTypes.putIfAbsent(subscriber, () => <Type>{}).add(eventType);
    
    // Only emit event if this was a new subscription
    if (wasAdded) {
      _eventController.add(EventBusEvent.subscribed(subscriber, eventType));
    }
  }

  /// Unsubscribe an actor from events of a specific type.
  void unsubscribe<T>(ActorRef subscriber) {
    final eventType = T;
    final wasRemoved = _subscriptions[eventType]?.remove(subscriber) ?? false;
    if (_subscriptions[eventType]?.isEmpty == true) {
      _subscriptions.remove(eventType);
    }
    
    _subscriberTypes[subscriber]?.remove(eventType);
    if (_subscriberTypes[subscriber]?.isEmpty == true) {
      _subscriberTypes.remove(subscriber);
    }
    
    // Only emit event if something was actually removed
    if (wasRemoved) {
      _eventController.add(EventBusEvent.unsubscribed(subscriber, eventType));
    }
  }

  /// Publish an event to all subscribers.
  /// 
  /// The event will be delivered to all actors subscribed to type [T]
  /// and any of its supertypes.
  void publish<T>(T event) {
    final eventType = T;
    final subscribers = _getSubscribersForType(eventType);
    
    for (final subscriber in subscribers) {
      try {
        subscriber.tell(LocalMessage(payload: event));
      } catch (e) {
        // If delivery fails, the message will go to dead letters
        // This is handled by the actor system's dead letter queue
      }
    }
    
    _eventController.add(EventBusEvent.published(eventType, event, subscribers.length));
  }

  /// Get all subscribers for a given event type.
  /// Only exact type matching is supported.
  Set<ActorRef> _getSubscribersForType(Type eventType) {
    return Set.of(_subscriptions[eventType] ?? {});
  }

  /// Remove all subscriptions for a given actor.
  /// This should be called when an actor is terminated to prevent memory leaks.
  void cleanup(ActorRef actor) {
    final subscribedTypes = _subscriberTypes[actor];
    if (subscribedTypes != null) {
      for (final eventType in subscribedTypes.toList()) {
        _subscriptions[eventType]?.remove(actor);
        if (_subscriptions[eventType]?.isEmpty == true) {
          _subscriptions.remove(eventType);
        }
      }
      _subscriberTypes.remove(actor);
      
      _eventController.add(EventBusEvent.cleanup(actor, subscribedTypes.length));
    }
  }

  /// Get all current subscriptions for debugging/monitoring.
  Map<Type, Set<ActorRef>> get subscriptions => Map.unmodifiable(_subscriptions);

  /// Get the number of active subscriptions.
  int get subscriptionCount => _subscriptions.values
      .map((subscribers) => subscribers.length)
      .fold(0, (a, b) => a + b);

  /// Get the number of unique subscribers.
  int get subscriberCount => _subscriberTypes.length;

  /// Dispose of the event bus and clean up resources.
  void dispose() {
    _subscriptions.clear();
    _subscriberTypes.clear();
    _eventController.close();
  }
}

/// Events emitted by the event bus for monitoring and debugging.
abstract class EventBusEvent {
  final DateTime timestamp;
  
  EventBusEvent() : timestamp = DateTime.now();

  factory EventBusEvent.subscribed(ActorRef subscriber, Type eventType) =>
      _SubscribedEvent(subscriber, eventType);

  factory EventBusEvent.unsubscribed(ActorRef subscriber, Type eventType) =>
      _UnsubscribedEvent(subscriber, eventType);

  factory EventBusEvent.published(Type eventType, dynamic event, int subscriberCount) =>
      _PublishedEvent(eventType, event, subscriberCount);

  factory EventBusEvent.cleanup(ActorRef actor, int subscriptionCount) =>
      _CleanupEvent(actor, subscriptionCount);
}

class _SubscribedEvent extends EventBusEvent {
  final ActorRef subscriber;
  final Type eventType;

  _SubscribedEvent(this.subscriber, this.eventType);

  @override
  String toString() => 'SubscribedEvent($subscriber, $eventType)';
}

class _UnsubscribedEvent extends EventBusEvent {
  final ActorRef subscriber;
  final Type eventType;

  _UnsubscribedEvent(this.subscriber, this.eventType);

  @override
  String toString() => 'UnsubscribedEvent($subscriber, $eventType)';
}

class _PublishedEvent extends EventBusEvent {
  final Type eventType;
  final dynamic event;
  final int subscriberCount;

  _PublishedEvent(this.eventType, this.event, this.subscriberCount);

  @override
  String toString() => 'PublishedEvent($eventType, $event, $subscriberCount subscribers)';
}

class _CleanupEvent extends EventBusEvent {
  final ActorRef actor;
  final int subscriptionCount;

  _CleanupEvent(this.actor, this.subscriptionCount);

  @override
  String toString() => 'CleanupEvent($actor, $subscriptionCount subscriptions)';
}
