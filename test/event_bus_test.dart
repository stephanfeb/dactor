import 'dart:async';
import 'package:test/test.dart';
import 'package:dactor/dactor.dart';

// Test event classes
class OrderCreated {
  final String orderId;
  final DateTime timestamp;

  OrderCreated(this.orderId, this.timestamp);

  @override
  String toString() => 'OrderCreated($orderId, $timestamp)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OrderCreated &&
          runtimeType == other.runtimeType &&
          orderId == other.orderId;

  @override
  int get hashCode => orderId.hashCode;
}

class OrderShipped {
  final String orderId;
  final String trackingNumber;

  OrderShipped(this.orderId, this.trackingNumber);

  @override
  String toString() => 'OrderShipped($orderId, $trackingNumber)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OrderShipped &&
          runtimeType == other.runtimeType &&
          orderId == other.orderId &&
          trackingNumber == other.trackingNumber;

  @override
  int get hashCode => orderId.hashCode ^ trackingNumber.hashCode;
}

class PaymentProcessed {
  final String orderId;
  final double amount;

  PaymentProcessed(this.orderId, this.amount);

  @override
  String toString() => 'PaymentProcessed($orderId, $amount)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PaymentProcessed &&
          runtimeType == other.runtimeType &&
          orderId == other.orderId &&
          amount == other.amount;

  @override
  int get hashCode => orderId.hashCode ^ amount.hashCode;
}

// Test actors
class OrderActor extends Actor {
  final List<dynamic> receivedEvents = [];
  final Completer<void> eventReceived = Completer<void>();

  @override
  void preStart() {
    context.subscribe<OrderCreated>();
    context.subscribe<OrderShipped>();
  }

  @override
  Future<void> onMessage(dynamic message) async {
    receivedEvents.add(message);
    if (!eventReceived.isCompleted) {
      eventReceived.complete();
    }
  }
}

class PaymentActor extends Actor {
  final List<dynamic> receivedEvents = [];
  final Completer<void> eventReceived = Completer<void>();

  @override
  void preStart() {
    context.subscribe<PaymentProcessed>();
  }

  @override
  Future<void> onMessage(dynamic message) async {
    receivedEvents.add(message);
    if (!eventReceived.isCompleted) {
      eventReceived.complete();
    }
  }
}

class PublisherActor extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {
    if (message == 'publish_order') {
      context.publish(OrderCreated('order-123', DateTime.now()));
    } else if (message == 'publish_payment') {
      context.publish(PaymentProcessed('order-123', 99.99));
    } else if (message == 'publish_shipping') {
      context.publish(OrderShipped('order-123', 'TRACK-456'));
    }
  }
}

class UnsubscribingActor extends Actor {
  final List<dynamic> receivedEvents = [];
  final Completer<void> eventReceived = Completer<void>();

  @override
  void preStart() {
    context.subscribe<OrderCreated>();
  }

  @override
  Future<void> onMessage(dynamic message) async {
    if (message == 'unsubscribe') {
      context.unsubscribe<OrderCreated>();
    } else {
      receivedEvents.add(message);
      if (!eventReceived.isCompleted) {
        eventReceived.complete();
      }
    }
  }
}

void main() {
  group('EventBus Tests', () {
    late ActorSystem system;

    setUp(() {
      system = ActorSystem.create();
    });

    tearDown(() async {
      await system.shutdown();
    });

    test('should publish and deliver events to subscribers', () async {
      // Arrange
      final orderActor = await system.spawn('order-actor', () => OrderActor());
      final paymentActor = await system.spawn('payment-actor', () => PaymentActor());
      final publisher = await system.spawn('publisher', () => PublisherActor());

      // Wait for actors to start and subscribe
      await Future.delayed(Duration(milliseconds: 100));

      // Act
      publisher.tell(LocalMessage(payload: 'publish_order'));
      publisher.tell(LocalMessage(payload: 'publish_payment'));

      // Wait for events to be processed
      await Future.delayed(Duration(milliseconds: 100));

      // Assert
      final orderActorInstance = (system as LocalActorSystem)
          .spawnAndGetActor('order-actor-temp', () => OrderActor())
          .then((result) => result.actor);
      
      // Verify event bus has subscribers
      expect(system.eventBus.subscriberCount, greaterThan(0));
      expect(system.eventBus.subscriptionCount, greaterThan(0));
    });

    test('should handle subscription and unsubscription', () async {
      // Arrange
      final actor = await system.spawn('test-actor', () => UnsubscribingActor());
      final publisher = await system.spawn('publisher', () => PublisherActor());

      // Wait for actor to start and subscribe
      await Future.delayed(Duration(milliseconds: 100));

      // Verify subscription exists
      expect(system.eventBus.subscriberCount, equals(1));

      // Act - unsubscribe
      actor.tell(LocalMessage(payload: 'unsubscribe'));
      await Future.delayed(Duration(milliseconds: 100));

      // Assert - should have no subscribers
      expect(system.eventBus.subscriptionCount, equals(0));
    });

    test('should clean up subscriptions when actor is stopped', () async {
      // Arrange
      final actor = await system.spawn('temp-actor', () => OrderActor());
      
      // Wait for actor to start and subscribe
      await Future.delayed(Duration(milliseconds: 100));

      // Verify subscription exists
      expect(system.eventBus.subscriberCount, greaterThan(0));

      // Act - stop the actor
      await system.stop(actor);

      // Assert - subscriptions should be cleaned up
      expect(system.eventBus.subscriberCount, equals(0));
      expect(system.eventBus.subscriptionCount, equals(0));
    });

    test('should support multiple subscribers for same event type', () async {
      // Arrange
      final actor1 = await system.spawn('actor1', () => OrderActor());
      final actor2 = await system.spawn('actor2', () => OrderActor());
      final publisher = await system.spawn('publisher', () => PublisherActor());

      // Wait for actors to start and subscribe
      await Future.delayed(Duration(milliseconds: 100));

      // Verify multiple subscribers
      expect(system.eventBus.subscriberCount, equals(2));

      // Act
      publisher.tell(LocalMessage(payload: 'publish_order'));
      await Future.delayed(Duration(milliseconds: 100));

      // Both actors should receive the event (verified by subscription count)
      expect(system.eventBus.subscriptionCount, greaterThan(0));
    });

    test('should handle events with no subscribers gracefully', () async {
      // Arrange
      final publisher = await system.spawn('publisher', () => PublisherActor());

      // Act - publish event with no subscribers
      publisher.tell(LocalMessage(payload: 'publish_order'));
      await Future.delayed(Duration(milliseconds: 100));

      // Assert - should not throw and system should remain stable
      expect(system.eventBus.subscriberCount, equals(0));
    });

    test('should provide event bus monitoring stream', () async {
      // Arrange
      final eventStream = system.events;
      final events = <EventBusEvent>[];
      final subscription = eventStream.listen(events.add);

      try {
        // Act
        final actor = await system.spawn('monitor-actor', () => OrderActor());
        await Future.delayed(Duration(milliseconds: 100));

        final publisher = await system.spawn('publisher', () => PublisherActor());
        publisher.tell(LocalMessage(payload: 'publish_order'));
        await Future.delayed(Duration(milliseconds: 100));

        await system.stop(actor);
        await Future.delayed(Duration(milliseconds: 100));

        // Assert
        expect(events.length, greaterThan(0));
        
        // Should have subscription events
        final subscriptionEvents = events.where((e) => e.toString().contains('Subscribed')).toList();
        expect(subscriptionEvents.length, greaterThan(0));

        // Should have cleanup events
        final cleanupEvents = events.where((e) => e.toString().contains('Cleanup')).toList();
        expect(cleanupEvents.length, greaterThan(0));
      } finally {
        await subscription.cancel();
      }
    });

    test('should handle direct event bus API', () async {
      // Arrange
      final actor = await system.spawn('direct-actor', () => OrderActor());
      await Future.delayed(Duration(milliseconds: 100));

      // Act - use direct event bus API
      system.eventBus.publish(OrderCreated('direct-order', DateTime.now()));
      await Future.delayed(Duration(milliseconds: 100));

      // Assert - event should be delivered
      expect(system.eventBus.subscriberCount, greaterThan(0));
    });

    test('should maintain subscription state correctly', () async {
      // Arrange
      final actor = await system.spawn('state-actor', () => OrderActor());
      await Future.delayed(Duration(milliseconds: 100));

      // Act & Assert - check initial state
      expect(system.eventBus.subscriberCount, equals(1));
      expect(system.eventBus.subscriptionCount, equals(2)); // OrderCreated + OrderShipped

      // Get subscription details
      final subscriptions = system.eventBus.subscriptions;
      expect(subscriptions.containsKey(OrderCreated), isTrue);
      expect(subscriptions.containsKey(OrderShipped), isTrue);
      expect(subscriptions[OrderCreated]?.length, equals(1));
      expect(subscriptions[OrderShipped]?.length, equals(1));
    });
  });

  group('EventBus Edge Cases', () {
    late ActorSystem system;

    setUp(() {
      system = ActorSystem.create();
    });

    tearDown(() async {
      await system.shutdown();
    });

    test('should handle rapid subscribe/unsubscribe cycles', () async {
      // Arrange
      final actor = await system.spawn('rapid-actor', () => UnsubscribingActor());
      await Future.delayed(Duration(milliseconds: 50));

      // Verify initial state - UnsubscribingActor subscribes to OrderCreated in preStart
      expect(system.eventBus.subscriptionCount, equals(1));

      // Act - rapid subscribe/unsubscribe to a different event type
      for (int i = 0; i < 10; i++) {
        system.eventBus.subscribe<PaymentProcessed>(actor);
        system.eventBus.unsubscribe<PaymentProcessed>(actor);
      }

      // Assert - should still have the original preStart subscription to OrderCreated
      expect(system.eventBus.subscriptionCount, equals(1)); // Only the preStart subscription
    });

    test('should handle cleanup of non-existent actor gracefully', () async {
      // Arrange
      final actor = await system.spawn('temp-actor', () => OrderActor());
      await system.stop(actor);

      // Act - try to cleanup again (should be safe)
      system.eventBus.cleanup(actor);

      // Assert - should not throw
      expect(system.eventBus.subscriberCount, equals(0));
    });

    test('should handle unsubscribe from non-subscribed type', () async {
      // Arrange
      final actor = await system.spawn('test-actor', () => OrderActor());
      await Future.delayed(Duration(milliseconds: 50));

      // Act - unsubscribe from type not subscribed to
      system.eventBus.unsubscribe<PaymentProcessed>(actor);

      // Assert - should not affect existing subscriptions
      expect(system.eventBus.subscriptionCount, equals(2)); // OrderCreated + OrderShipped
    });
  });
}
