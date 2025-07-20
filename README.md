# Dactor - Actor System for Dart

**A lightweight, high-performance actor model implementation for Dart**

Dactor provides a robust actor system for building concurrent, fault-tolerant, and scalable applications in Dart. It implements the actor model with features like supervision trees, message passing, ask patterns with reliability, metrics, and pooling.

[![Pub Version](https://img.shields.io/pub/v/dactor)](https://pub.dev/packages/dactor)
[![Dart SDK](https://img.shields.io/badge/dart-%3E%3D3.5.1-blue)](https://dart.dev)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

## ✨ Features

- 🎯 **Pure Actor Model**: Type-safe message passing with actor isolation
- 🔄 **Reliable Ask Pattern**: Request-response with configurable retries and exponential backoff  
- 🛡️ **Fault Tolerance**: Supervision trees with customizable recovery strategies
- 📡 **Event Bus**: Publish-subscribe messaging for event-driven architectures
- ⏰ **Actor Timers**: Schedule messages with single-shot, fixed-delay, and fixed-rate timers
- ⚡ **High Performance**: >29K messages/sec throughput, <1ms latency
- 📊 **Built-in Observability**: Comprehensive metrics, tracing, and monitoring
- 🎛️ **Actor Pooling**: Scale with worker pools and round-robin routing
- 💾 **Memory Efficient**: <1KB overhead per actor
- 🔍 **Dead Letter Queue**: Handle undeliverable messages gracefully
- 🚀 **Zero Dependencies**: Pure Dart implementation

## 🚀 Quick Start

Add to your `pubspec.yaml`:

```yaml
dependencies:
  dactor: ^1.0.0
```

### Basic Example

```dart
import 'package:dactor/dactor.dart';

// Define an actor
class CounterActor extends Actor {
  int _count = 0;

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is LocalMessage) {
      switch (message.payload) {
        case 'increment':
          _count++;
          print('Count: $_count');
          message.sender?.tell(LocalMessage(payload: _count));
          break;
        case 'get':
          message.sender?.tell(LocalMessage(payload: _count));
          break;
      }
    }
  }

  @override
  void preStart() => print('Counter actor started');

  @override
  void postStop() => print('Counter actor stopped');
}

void main() async {
  // Create actor system
  final system = LocalActorSystem();
  
  // Spawn an actor
  final counter = await system.spawn('counter', () => CounterActor());
  
  // Send messages (fire-and-forget)
  counter.tell(LocalMessage(payload: 'increment'));
  counter.tell(LocalMessage(payload: 'increment'));
  
  // Ask pattern (request-response)
  final count = await counter.ask(
    LocalMessage(payload: 'get'),
    Duration(seconds: 1),
  );
  print('Current count: ${(count as LocalMessage).payload}');
  
  await system.shutdown();
}
```

## 📚 Core Concepts

### Actor Lifecycle

Actors have a well-defined lifecycle managed by the system:

```dart
class MyActor extends Actor {
  @override
  void preStart() {
    // Called when actor starts
    print('Actor ${context.self.id} starting');
  }

  @override
  Future<void> onMessage(dynamic message) async {
    // Handle incoming messages
    print('Received: $message');
  }

  @override
  void postStop() {
    // Called when actor stops (cleanup)
    print('Actor ${context.self.id} stopped');
  }
}
```

### Message Passing

Messages are the primary communication mechanism:

```dart
// Simple message
counter.tell(LocalMessage(payload: 'increment'));

// Message with sender - IMPORTANT: Pass sender as separate parameter
counter.tell(LocalMessage(payload: 'ping'), sender: otherActor);

// Custom message types
class CustomMessage implements Message {
  final String data;
  CustomMessage(this.data);
  
  // Implement Message interface
  @override
  String get correlationId => 'custom';
  @override
  Map<String, dynamic> get metadata => {};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}
```

#### ⚠️ Critical: Proper Sender Passing

When sending messages that expect a reply, **always pass the sender as a separate parameter** to the `tell()` method:

```dart
// ✅ CORRECT: Sender passed as separate parameter
actor.tell(LocalMessage(payload: 'request'), sender: probe.ref);

// ❌ INCORRECT: Trying to embed sender in message
actor.tell(LocalMessage(payload: 'request', sender: probe.ref)); // This won't work!
```

The actor system automatically sets `context.sender` when processing messages, but only when the sender is passed correctly as a parameter to `tell()`.

## 🎯 Ask Pattern with Reliability

The ask pattern provides reliable request-response messaging with configurable retries:

### Basic Ask Pattern

```dart
// Simple ask with timeout
final response = await actor.ask('ping', Duration(seconds: 1));

// With custom message
final result = await actor.ask(
  LocalMessage(payload: 'get_data'),
  Duration(seconds: 5),
);
```

### Configurable Reliability

```dart
// Development configuration (longer timeouts, more retries)
final system = ActorSystem.create(ActorSystemConfig(
  askConfig: AskConfig.development(),
));

// Production configuration (shorter timeouts, fewer retries)
final system = ActorSystem.create(ActorSystemConfig(
  askConfig: AskConfig.production(),
));

// Custom configuration
final system = ActorSystem.create(ActorSystemConfig(
  askConfig: AskConfig(
    defaultTimeout: Duration(seconds: 3),
    maxRetries: 2,
    retryBackoffBase: Duration(milliseconds: 100),
    retryBackoffMultiplier: 2.0,
    maxBackoffDuration: Duration(seconds: 5),
  ),
));

// Disable retries entirely
final system = ActorSystem.create(ActorSystemConfig(
  askConfig: AskConfig.noRetries(),
));
```

### Exponential Backoff

The system automatically calculates backoff delays:

```dart
final config = AskConfig(
  retryBackoffBase: Duration(milliseconds: 100),
  retryBackoffMultiplier: 2.0,
);

// Retry attempts will wait:
// 1st retry: 100ms
// 2nd retry: 200ms  
// 3rd retry: 400ms
// 4th retry: 800ms (and so on...)
```

## 🛡️ Supervision and Fault Tolerance

Actors can supervise children and handle failures gracefully:

```dart
class WorkerActor extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {
    if (message == 'fail') {
      throw Exception('Simulated failure');
    }
    // Handle other messages...
  }
}

class MySupervisor extends SupervisorActor {
  MySupervisor() : super(
    AllForOneStrategy(
      decider: (error, stackTrace) => SupervisionDecision.restart,
      maxRetries: 3,
    ),
  );

  @override
  Future<void> onMessage(dynamic message) async {
    if (message == 'create_worker') {
      await supervise('worker', () => WorkerActor());
    }
  }
}

// Usage
final supervisor = await system.spawn('supervisor', () => MySupervisor());
supervisor.tell('create_worker');
```

### Supervision Strategies

**OneForOneStrategy**: Only the failed actor is affected
```dart
final strategy = OneForOneStrategy(
  decider: (error, stackTrace) => SupervisionDecision.restart,
  maxRetries: 3,
);
```

**AllForOneStrategy**: All supervised actors are affected by one failure
```dart
final strategy = AllForOneStrategy(
  decider: (error, stackTrace) => SupervisionDecision.restart,
  maxRetries: 1,
);
```

**Supervision Decisions**:
- `SupervisionDecision.restart` - Restart the failed actor
- `SupervisionDecision.stop` - Stop the failed actor permanently
- `SupervisionDecision.escalate` - Pass the failure up to the parent

## ⚡ Actor Pooling for Scalability

Scale your actors with worker pools:

```dart
// Create a pool of 4 worker actors
final router = await system.spawn(
  'worker-router',
  () => WorkerActor(),
  pool: Pool(workerCount: 4),
);

// Messages are distributed round-robin to workers
for (int i = 0; i < 100; i++) {
  router.tell(LocalMessage(payload: 'task_$i'));
}
```

## ⏰ Actor Timers for Scheduled Messages

Dactor provides Akka-style Timer actors that allow you to schedule messages to be sent to an actor at specific times or intervals. Timers are automatically bound to the actor's lifecycle and are cancelled when the actor is stopped or restarted.

### Timer Types

**Single-Shot Timers**: Send a message once after a delay
```dart
class TimeoutActor extends Actor {
  @override
  void preStart() {
    // Send timeout message after 30 seconds
    context.timers.startSingleTimer(
      'timeout', 
      'session-expired', 
      Duration(seconds: 30)
    );
  }
  
  @override
  Future<void> onMessage(dynamic message) async {
    if (message == 'activity') {
      // Reset timeout on activity
      context.timers.startSingleTimer(
        'timeout', 
        'session-expired', 
        Duration(seconds: 30)
      );
    } else if (message == 'session-expired') {
      print('Session expired due to inactivity');
      context.system.stop(context.self);
    }
  }
}
```

**Fixed Delay Timers**: Send messages repeatedly with consistent spacing
```dart
class HeartbeatActor extends Actor {
  @override
  void preStart() {
    // Send heartbeat every 30 seconds with fixed delay
    context.timers.startTimerWithFixedDelay(
      'heartbeat', 
      'send-heartbeat', 
      Duration(seconds: 30)
    );
  }
  
  @override
  Future<void> onMessage(dynamic message) async {
    if (message == 'send-heartbeat') {
      await sendHeartbeatToServer();
      print('Heartbeat sent');
    }
  }
  
  Future<void> sendHeartbeatToServer() async {
    // Implementation for sending heartbeat
  }
}
```

**Fixed Rate Timers**: Send messages at exact intervals with catch-up behavior
```dart
class MetricsCollectorActor extends Actor {
  @override
  void preStart() {
    // Collect metrics every minute at fixed rate
    context.timers.startTimerAtFixedRate(
      'collect', 
      'collect-metrics', 
      Duration(minutes: 1)
    );
  }
  
  @override
  Future<void> onMessage(dynamic message) async {
    if (message == 'collect-metrics') {
      final metrics = await collectSystemMetrics();
      await storeMetrics(metrics);
    }
  }
}
```

### Timer Management

**Key-Based Timer Replacement**
```dart
class RequestTimeoutActor extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {
    if (message is StartRequest) {
      // Set timeout for this request (replaces any existing timeout)
      context.timers.startSingleTimer(
        'request-timeout',
        RequestTimeout(message.requestId),
        Duration(seconds: 5)
      );
    } else if (message is RequestCompleted) {
      // Cancel timeout as request completed successfully
      context.timers.cancel('request-timeout');
    } else if (message is RequestTimeout) {
      print('Request ${message.requestId} timed out');
    }
  }
}
```

**Timer Lifecycle Management**
```dart
class CacheManagerActor extends Actor {
  @override
  void preStart() {
    // Start periodic cleanup
    context.timers.startTimerWithFixedDelay(
      'cleanup', 'cleanup-expired', Duration(minutes: 5));
    
    // Start periodic stats collection
    context.timers.startTimerAtFixedRate(
      'stats', 'collect-stats', Duration(minutes: 1));
  }
  
  @override
  Future<void> onMessage(dynamic message) async {
    switch (message) {
      case 'cleanup-expired':
        await cleanupExpiredEntries();
        break;
      case 'collect-stats':
        await collectCacheStats();
        break;
      case 'shutdown':
        // Cancel all timers before shutdown
        context.timers.cancelAll();
        break;
    }
  }
  
  @override
  void postStop() {
    // Timers are automatically cancelled when actor stops
    print('Cache manager stopped - all timers cancelled');
  }
}
```

### Timer API Reference

```dart
// Start timers
context.timers.startSingleTimer(key, message, delay);
context.timers.startTimerWithFixedDelay(key, message, delay);
context.timers.startTimerAtFixedRate(key, message, interval);

// Manage timers  
context.timers.cancel(key);           // Cancel specific timer
context.timers.cancelAll();           // Cancel all timers
context.timers.isTimerActive(key);    // Check if timer is active
context.timers.activeTimers;          // List all active timer keys
```

### Timer Features

- **Automatic Cleanup**: Timers are automatically cancelled when actors stop or restart
- **Key-Based Replacement**: Starting a timer with an existing key cancels the previous timer
- **Lifecycle Bound**: Timer messages are guaranteed not to be received after actor termination
- **High Performance**: Built on Dart's efficient Timer implementation
- **Memory Safe**: No memory leaks from cancelled or completed timers

### Common Timer Patterns

**Session Management**
```dart
class SessionActor extends Actor {
  @override
  void preStart() {
    scheduleExpiration();
  }
  
  void scheduleExpiration() {
    context.timers.startSingleTimer(
      'expire', 'expire-session', Duration(minutes: 30));
  }
  
  @override
  Future<void> onMessage(dynamic message) async {
    switch (message) {
      case UserActivity():
        scheduleExpiration(); // Reset expiration timer
        break;
      case 'expire-session':
        print('Session expired');
        context.system.stop(context.self);
        break;
    }
  }
}
```

**Rate Limiting**
```dart
class RateLimiterActor extends Actor {
  int _requestCount = 0;
  
  @override
  void preStart() {
    // Reset counter every minute
    context.timers.startTimerAtFixedRate(
      'reset', 'reset-counter', Duration(minutes: 1));
  }
  
  @override
  Future<void> onMessage(dynamic message) async {
    if (message == 'request') {
      if (_requestCount < 100) {
        _requestCount++;
        context.sender?.tell(LocalMessage(payload: 'allowed'));
      } else {
        context.sender?.tell(LocalMessage(payload: 'rate-limited'));
      }
    } else if (message == 'reset-counter') {
      _requestCount = 0;
    }
  }
}
```

## 📡 Event Bus for Event-Driven Architecture

The event bus enables publish-subscribe messaging patterns for building event-driven applications:

### Basic Event Publishing and Subscription

```dart
// Define event types
class OrderCreated {
  final String orderId;
  final DateTime timestamp;
  final double amount;
  
  OrderCreated(this.orderId, this.timestamp, this.amount);
}

class PaymentProcessed {
  final String orderId;
  final double amount;
  
  PaymentProcessed(this.orderId, this.amount);
}

// Publisher actor
class OrderService extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {
    if (message is LocalMessage && message.payload == 'create_order') {
      final orderId = 'ORDER-${DateTime.now().millisecondsSinceEpoch}';
      
      // Publish event to all subscribers
      context.publish(OrderCreated(orderId, DateTime.now(), 99.99));
    }
  }
}

// Subscriber actor
class PaymentService extends Actor {
  @override
  void preStart() {
    // Subscribe to order events
    context.subscribe<OrderCreated>();
  }

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is OrderCreated) {
      print('Processing payment for order: ${message.orderId}');
      
      // Process payment and publish completion event
      context.publish(PaymentProcessed(message.orderId, message.amount));
    }
  }
}
```

### Event Bus API

```dart
// Subscribe to events (typically in preStart)
context.subscribe<OrderCreated>();

// Publish events
context.publish(OrderCreated('order-123', DateTime.now(), 99.99));

// Unsubscribe from events
context.unsubscribe<OrderCreated>();

// Direct event bus access
system.eventBus.subscribe<OrderCreated>(actorRef);
system.eventBus.publish(OrderCreated('order-123', DateTime.now(), 99.99));
system.eventBus.unsubscribe<OrderCreated>(actorRef);
```

### Event-Driven Microservices

```dart
class OrderProcessingSystem {
  late ActorSystem system;
  
  Future<void> start() async {
    system = ActorSystem.create();
    
    // Spawn services that communicate via events
    await system.spawn('order-service', () => OrderService());
    await system.spawn('payment-service', () => PaymentService());
    await system.spawn('shipping-service', () => ShippingService());
    await system.spawn('notification-service', () => NotificationService());
  }
}

class ShippingService extends Actor {
  @override
  void preStart() {
    context.subscribe<PaymentProcessed>();
  }

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is PaymentProcessed) {
      print('Shipping order: ${message.orderId}');
      context.publish(OrderShipped(message.orderId, 'TRACK-123'));
    }
  }
}

class NotificationService extends Actor {
  @override
  void preStart() {
    // Subscribe to all order events
    context.subscribe<OrderCreated>();
    context.subscribe<PaymentProcessed>();
    context.subscribe<OrderShipped>();
  }

  @override
  Future<void> onMessage(dynamic message) async {
    switch (message.runtimeType) {
      case OrderCreated:
        print('📧 Order confirmation sent');
        break;
      case PaymentProcessed:
        print('📧 Payment confirmation sent');
        break;
      case OrderShipped:
        print('📧 Shipping notification sent');
        break;
    }
  }
}
```

### Saga Pattern Implementation

```dart
class OrderSaga extends Actor {
  final Map<String, SagaState> _sagas = {};

  @override
  void preStart() {
    context.subscribe<OrderCreated>();
    context.subscribe<PaymentProcessed>();
    context.subscribe<PaymentFailed>();
    context.subscribe<OrderShipped>();
  }

  @override
  Future<void> onMessage(dynamic message) async {
    switch (message.runtimeType) {
      case OrderCreated:
        final event = message as OrderCreated;
        _sagas[event.orderId] = SagaState.orderCreated;
        // Trigger payment processing
        context.publish(ProcessPayment(event.orderId, event.amount));
        break;
        
      case PaymentProcessed:
        final event = message as PaymentProcessed;
        if (_sagas[event.orderId] == SagaState.orderCreated) {
          _sagas[event.orderId] = SagaState.paymentProcessed;
          // Trigger shipping
          context.publish(ShipOrder(event.orderId));
        }
        break;
        
      case PaymentFailed:
        final event = message as PaymentFailed;
        // Compensate: cancel order
        context.publish(CancelOrder(event.orderId));
        _sagas.remove(event.orderId);
        break;
        
      case OrderShipped:
        final event = message as OrderShipped;
        // Saga completed successfully
        _sagas.remove(event.orderId);
        break;
    }
  }
}

enum SagaState { orderCreated, paymentProcessed, shipped }
```

### Event Bus Monitoring

```dart
// Monitor event bus activity
final eventStream = system.events;
eventStream.listen((event) {
  print('Event bus activity: $event');
});

// Check event bus metrics
print('Active subscribers: ${system.eventBus.subscriberCount}');
print('Total subscriptions: ${system.eventBus.subscriptionCount}');
```

### Event Bus Features

- **Type-Safe**: Events are strongly typed using Dart's type system
- **Automatic Cleanup**: Subscriptions are automatically removed when actors stop
- **High Performance**: Efficient O(1) routing for direct type matches
- **Memory Safe**: No memory leaks from orphaned subscriptions
- **Observable**: Built-in monitoring stream for debugging and metrics

## 📊 Metrics and Observability

Built-in metrics for monitoring your actor system:

```dart
// Create system with metrics
final metrics = InMemoryMetricsCollector();
final system = ActorSystem.create(ActorSystemConfig(
  metricsCollector: metrics,
));

// Spawn actors and send messages...
final actor = await system.spawn('test', () => MyActor());
actor.tell('hello');

// Check metrics
print('Actors spawned: ${metrics.getCounter('actors.spawned')}');
print('Active actors: ${metrics.getGauge('actors.active')}');
print('Messages processed: ${metrics.getCounter('messages.processed')}');
print('Processing times: ${metrics.getTimings('messages.processing_time')}');
```

Available metrics:
- `actors.spawned` - Total actors created
- `actors.active` - Current active actors
- `actors.stopped` - Total actors stopped
- `actors.failed` - Total actor failures
- `messages.processed` - Total messages processed
- `messages.processing_time` - Message processing latencies
- `dead_letters` - Undeliverable messages
- `mailbox.size` - Current mailbox sizes

## 🔍 Dead Letter Queue

Handle undeliverable messages:

```dart
final actor = await system.spawn('test', () => MyActor());
await system.stop(actor);

// This message will go to dead letters
actor.tell('late_message');

// Check dead letter queue
final deadLetter = system.deadLetterQueue.dequeue();
if (deadLetter != null) {
  print('Undelivered message: ${deadLetter.message}');
  print('Intended recipient: ${deadLetter.recipient}');
}
```

## 🎮 Real-World Examples

### Chat Server

```dart
class ChatRoom extends Actor {
  final Set<ActorRef> _participants = {};

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is JoinRoom) {
      _participants.add(message.user);
      message.user.tell('Welcome to the chat!');
    } else if (message is ChatMessage) {
      // Broadcast to all participants
      for (final participant in _participants) {
        participant.tell('${message.sender}: ${message.text}');
      }
    } else if (message is LeaveRoom) {
      _participants.remove(message.user);
    }
  }
}

class JoinRoom {
  final ActorRef user;
  JoinRoom(this.user);
}

class ChatMessage {
  final String sender;
  final String text;
  ChatMessage(this.sender, this.text);
}
```

### Game Entity System

```dart
class GameEntity extends Actor {
  double x = 0, y = 0;
  int health = 100;

  @override
  Future<void> onMessage(dynamic message) async {
    switch (message.runtimeType) {
      case MoveCommand:
        final move = message as MoveCommand;
        x += move.deltaX;
        y += move.deltaY;
        // Notify other systems
        context.system.eventBus.publish(EntityMoved(context.self, x, y));
        break;
        
      case DamageCommand:
        final damage = message as DamageCommand;
        health -= damage.amount;
        if (health <= 0) {
          context.system.eventBus.publish(EntityDestroyed(context.self));
          context.stop();
        }
        break;
    }
  }
}
```

### Microservice Coordination

```dart
class OrderService extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {
    if (message is ProcessOrder) {
      try {
        // Validate order
        final validation = await context.system
            .actorOf('validation-service')
            .ask(ValidateOrder(message.order), Duration(seconds: 5));
            
        if (validation.isValid) {
          // Process payment
          final payment = await context.system
              .actorOf('payment-service')
              .ask(ProcessPayment(message.order), Duration(seconds: 10));
              
          if (payment.successful) {
            // Ship order
            context.system
                .actorOf('shipping-service')
                .tell(ShipOrder(message.order));
          }
        }
      } catch (e) {
        // Handle service failures
        context.system
            .actorOf('notification-service')
            .tell(OrderFailed(message.order, e.toString()));
      }
    }
  }
}
```

## ⚙️ Configuration

### Actor System Configuration

```dart
final config = ActorSystemConfig(
  // Ask pattern configuration
  askConfig: AskConfig(
    defaultTimeout: Duration(seconds: 5),
    maxRetries: 3,
    retryBackoffBase: Duration(milliseconds: 100),
  ),
  
  // Metrics collection
  metricsCollector: InMemoryMetricsCollector(),
  
  // Dispatcher configuration
  dispatcherConfig: DispatcherConfig(
    corePoolSize: 4,
    maximumPoolSize: 8,
  ),
);

final system = ActorSystem.create(config);
```

## 🚀 Performance

Dactor is designed for high performance:

- **Throughput**: >29,000 messages/second
- **Latency**: <112μs average message processing
- **Memory**: <1KB overhead per idle actor
- **Scalability**: Supports thousands of concurrent actors

Run the benchmarks:

```bash
dart test test/benchmark/
```

Example benchmark results:
```
Single Actor - Processed 100000 messages in 3401ms
Single Actor - Throughput: 29403.69 msg/sec

Pooled Actor - Processed 100000 messages in 1250ms  
Pooled Actor - Throughput: 80000.00 msg/sec
```

## 🧪 Testing Your Actors

Dactor includes a dedicated testing toolkit to help you write reliable tests for your actors. The primary tools are `TestActorSystem` and `TestProbe`.

### TestActorSystem

For testing, you should use `TestActorSystem` instead of `LocalActorSystem`. It provides helper methods for creating testing utilities like probes.

```dart
import 'package:dactor/dactor.dart';
import 'package:test/test.dart';

void main() {
  group('My Actor Tests', () {
    late TestActorSystem system;
    
    setUp(() {
      // Use TestActorSystem for your tests
      system = TestActorSystem();
    });
    
    tearDown(() async {
      await system.shutdown();
    });

    // ... your tests
  });
}
```

### TestProbe: Your Testing Companion

A `TestProbe` is a special actor that you can use to send messages to your actors and assert the replies. It acts as a "black box" test double with enhanced capabilities for robust testing.

#### Enhanced TestProbe API

The `TestProbe` provides several methods for testing actor interactions:

```dart
// Create a probe
final probe = await system.createProbe();

// Expect a specific message
await probe.expectMsg('expected_payload');

// Expect a message with timeout
await probe.expectMsg('expected_payload', timeout: Duration(seconds: 5));

// Expect a message of specific type
final msg = await probe.expectMsgType<String>();
final msg = await probe.expectMsgType<MyCustomType>(timeout: Duration(seconds: 3));

// Access the last received message
final lastMsg = probe.lastMessage;

// Reply to the sender of the last message
probe.reply('response_payload');
```

#### Expecting Messages

You can use a probe to verify that your actor sends an expected message.

```dart
class MyActor extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {
    if (message == 'ping') {
      context.sender?.tell(LocalMessage(payload: 'pong'));
    }
  }
}

test('should respond with pong', () async {
  // 1. Create a probe
  final probe = await system.createProbe();
  
  // 2. Spawn the actor under test
  final actor = await system.spawn('my-actor', () => MyActor());
  
  // 3. Send a message from the probe to the actor (CORRECT sender passing)
  actor.tell(LocalMessage(payload: 'ping'), sender: probe.ref);
  
  // 4. Assert that the probe receives the expected reply
  await probe.expectMsg('pong');
});
```

#### Type-Safe Message Expectations

Use `expectMsgType<T>()` for type-safe message assertions:

```dart
test('should receive typed message', () async {
  final probe = await system.createProbe();
  final actor = await system.spawn('test', () => MyActor());
  
  actor.tell(LocalMessage(payload: 'get_number'), sender: probe.ref);
  
  // Expect a message of specific type and get it back
  final number = await probe.expectMsgType<int>(timeout: Duration(seconds: 2));
  expect(number, greaterThan(0));
});
```

#### Replying from a Probe

A probe can also reply to messages, allowing you to test more complex interactions.

```dart
class AskerActor extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {
    if (message == 'ask_and_reply') {
      final response = await context.sender?.ask(LocalMessage(payload: 'question'));
      context.sender?.tell(LocalMessage(payload: 'response: ${response?.payload}'));
    }
  }
}

test('should handle replies from probe', () async {
  final probe = await system.createProbe();
  final actor = await system.spawn('asker', () => AskerActor());

  actor.tell(LocalMessage(payload: 'ask_and_reply'), sender: probe.ref);

  // Expect the question from the actor
  await probe.expectMsg('question');
  
  // Reply from the probe
  probe.reply('answer');

  // Expect the final response
  await probe.expectMsg('response: answer');
});
```

#### Testing Best Practices

1. **Always pass sender correctly**: Use `actor.tell(message, sender: probe.ref)` not `actor.tell(LocalMessage(payload: data, sender: probe.ref))`

2. **Use timeouts for reliability**: Always specify timeouts for `expectMsg` and `expectMsgType` in production tests

3. **Leverage type safety**: Use `expectMsgType<T>()` when you know the expected message type

4. **Access last message**: Use `probe.lastMessage` to inspect the most recent message for detailed assertions

### Tracing Message Flow

For more complex scenarios, you can trace the entire flow of a message through the system. This is useful for debugging and ensuring messages are processed correctly.

To enable tracing, configure your `TestActorSystem` with an `InMemoryTraceCollector`.

```dart
import 'package:dactor/src/tracing/tracing.dart';

class HelloActor extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {
    if (message.payload.toString() == 'hello') {
      context.sender?.tell(LocalMessage(payload: 'world'));
    }
  }
}

void main() {
  group('Message Tracing', () {
    late TestActorSystem system;
    late InMemoryTraceCollector collector;

    setUp(() {
      // 1. Create a collector
      collector = InMemoryTraceCollector();
      // 2. Create the system with the collector
      system = TestActorSystem(ActorSystemConfig(traceCollector: collector));
    });

    tearDown(() async => await system.shutdown());

    test('should trace message flow', () async {
      final probe = await system.createProbe();
      final actor = await system.spawn('test', () => HelloActor());

      // Send a message with the probe as the sender
      final message = LocalMessage(payload: 'hello', sender: probe.ref);
      actor.tell(message);

      // Wait for messages to be processed
      await probe.expectMsg('world');

      // 3. Inspect the trace
      final trace = collector.traces[message.correlationId];
      expect(trace, isNotNull);
      expect(trace!.length, 2);
      expect(trace[0].event, 'sent');
      expect(trace[1].event, 'processed');
    });
  });
}
```

The `InMemoryTraceCollector` stores a list of `TraceEvent` objects for each `correlationId`. Each event records what happened to the message (e.g., `sent`, `processed`, `replied`) and which actor was involved.

## 🎯 Best Practices

### 1. Design for Immutability
```dart
// Good: Immutable message
class OrderCreated {
  final String orderId;
  final DateTime timestamp;
  final List<String> items;
  
  const OrderCreated(this.orderId, this.timestamp, this.items);
}

// Avoid: Mutable state in messages
class BadMessage {
  String data; // Mutable field
  BadMessage(this.data);
}
```

### 2. Use Supervision Hierarchies
```dart
// Create supervision trees for fault isolation
final supervisor = await system.spawn('app-supervisor', () => AppSupervisor());
final dbSupervisor = await supervisor.supervise('db-supervisor', () => DbSupervisor());
final worker = await dbSupervisor.supervise('db-worker', () => DbWorker());
```

### 3. Configure Ask Pattern Appropriately
```dart
// Use development config during development
final devSystem = ActorSystem.create(ActorSystemConfig(
  askConfig: AskConfig.development(), // 30s timeout, 5 retries
));

// Use production config in production
final prodSystem = ActorSystem.create(ActorSystemConfig(
  askConfig: AskConfig.production(), // 3s timeout, 2 retries
));
```

### 4. Monitor with Metrics
```dart
// Always enable metrics in production
final system = ActorSystem.create(ActorSystemConfig(
  metricsCollector: InMemoryMetricsCollector(),
));

// Regularly check system health
Timer.periodic(Duration(minutes: 1), (_) {
  final activeActors = metrics.getGauge('actors.active');
  final failedActors = metrics.getCounter('actors.failed');
  print('System health: $activeActors active, $failedActors failed');
});
```

## 🔧 Advanced Features

### Custom Message Types
```dart
abstract class GameMessage implements Message {
  @override
  String get correlationId => 'game-${DateTime.now().millisecondsSinceEpoch}';
  
  @override
  Map<String, dynamic> get metadata => {'game': true};
  
  @override
  ActorRef? get replyTo => null;
  
  @override
  DateTime get timestamp => DateTime.now();
}

class PlayerMove extends GameMessage {
  final String playerId;
  final double x, y;
  PlayerMove(this.playerId, this.x, this.y);
}
```

### Actor Context Usage
```dart
class ContextActor extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {
    // Access actor context
    print('My ID: ${context.self.id}');
    print('Parent: ${context.parent?.id}');
    print('System: ${context.system}');
    
    // Create child actors
    final child = await context.actorOf('child', () => ChildActor());
    
    // Stop child actors
    await context.stop(child);
    
    // Access children
    print('Children: ${context.children.map((c) => c.id)}');
  }
}
```

## 📖 API Reference

### Core Classes

- **`Actor`** - Base class for all actors
- **`ActorRef`** - Reference to an actor for sending messages
- **`ActorSystem`** - Manages actor lifecycle and messaging
- **`EventBus`** - Manages event subscriptions and publishing
- **`Message`** - Interface for messages passed between actors
- **`SupervisorActor`** - Base class for supervising other actors
- **`TimerScheduler`** - Manages scheduled message delivery within actors

### Key Methods

**Actor System:**
- **`system.spawn(id, factory)`** - Create a new actor
- **`actor.tell(message)`** - Send fire-and-forget message
- **`actor.ask(message, timeout)`** - Send request-response message
- **`system.stop(actor)`** - Stop an actor gracefully
- **`system.shutdown()`** - Shutdown the entire system

**Event Bus:**
- **`context.publish<T>(event)`** - Publish an event to all subscribers
- **`context.subscribe<T>()`** - Subscribe to events of type T
- **`context.unsubscribe<T>()`** - Unsubscribe from events of type T
- **`system.eventBus.publish<T>(event)`** - Direct event bus publishing
- **`system.eventBus.subscribe<T>(actor)`** - Direct event bus subscription
- **`system.events`** - Stream of event bus monitoring events

**Timer Scheduler:**
- **`context.timers.startSingleTimer(key, message, delay)`** - Schedule single message
- **`context.timers.startTimerWithFixedDelay(key, message, delay)`** - Schedule with fixed delay
- **`context.timers.startTimerAtFixedRate(key, message, interval)`** - Schedule at fixed rate
- **`context.timers.cancel(key)`** - Cancel specific timer
- **`context.timers.cancelAll()`** - Cancel all timers
- **`context.timers.isTimerActive(key)`** - Check if timer is active

## 🤝 Contributing

We welcome contributions! Please see our [Contributing Guide](CONTRIBUTING.md) for details.

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- Inspired by the Akka actor system
- Built for the Dart ecosystem
- Designed for OverNode's distributed architecture

---

**Ready to build fault-tolerant, concurrent applications?** 

```bash
dart pub add dactor
```

Start building with actors today! 🚀
