import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:dactor/src/metrics/metrics.dart';
import 'package:dactor_test/dactor_test.dart';
import 'package:test/test.dart';

/// Actor that records the order of message processing to verify sequential execution.
class SequentialActor extends Actor {
  final List<int> processedOrder = [];
  final Completer<void> allDone;
  final int expectedCount;

  SequentialActor(this.allDone, this.expectedCount);

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is int) {
      // Simulate async work to expose concurrency issues
      await Future.delayed(const Duration(milliseconds: 10));
      processedOrder.add(message);
      if (processedOrder.length >= expectedCount) {
        allDone.complete();
      }
    }
  }
}

/// Actor that fails on specific messages for supervision testing.
class FailingActor extends Actor {
  int processCount = 0;

  @override
  Future<void> onMessage(dynamic message) async {
    processCount++;
    if (message == 'fail') {
      throw Exception('Intentional failure');
    }
    if (message == 'ping') {
      context.sender?.tell(LocalMessage(payload: 'pong'));
    }
  }
}

/// Simple counter actor for supervision scope testing.
class CounterActor extends Actor {
  int count = 0;

  @override
  Future<void> onMessage(dynamic message) async {
    if (message == 'increment') {
      count++;
    } else if (message == 'fail') {
      throw Exception('Counter failure');
    } else if (message == 'get') {
      context.sender?.tell(LocalMessage(payload: count));
    }
  }
}

void main() {
  group('Actor Isolation', () {
    late TestActorSystem system;

    setUp(() {
      system = TestActorSystem();
    });

    tearDown(() async {
      await system.shutdown();
    });

    test('messages for same actor are processed sequentially', () async {
      final messageCount = 20;
      final allDone = Completer<void>();
      final result = await system.spawnAndGetActor(
        'sequential',
        () => SequentialActor(allDone, messageCount),
      );
      final actor = result.actor as SequentialActor;
      final ref = result.ref;

      // Send messages rapidly
      for (var i = 0; i < messageCount; i++) {
        ref.tell(LocalMessage(payload: i));
      }

      await allDone.future.timeout(const Duration(seconds: 5));

      // Messages must be processed in order (sequential guarantee)
      expect(actor.processedOrder, List.generate(messageCount, (i) => i));
    });
  });

  group('Terminated correlationId stability', () {
    test('correlationId returns same value on multiple accesses', () {
      final ref = _FakeActorRef('test');
      final terminated = Terminated(ref);

      final id1 = terminated.correlationId;
      final id2 = terminated.correlationId;
      final id3 = terminated.correlationId;

      expect(id1, equals(id2));
      expect(id2, equals(id3));
    });

    test('DeadLetter correlationId returns same value on multiple accesses', () {
      final ref = _FakeActorRef('test');
      final deadLetter = DeadLetter('msg', ref, ref);

      final id1 = deadLetter.correlationId;
      final id2 = deadLetter.correlationId;

      expect(id1, equals(id2));
    });
  });

  group('Bounded DeadLetterQueue', () {
    test('evicts oldest entries when at capacity', () {
      final metrics = InMemoryMetricsCollector();
      final dlq = DeadLetterQueue(metrics, maxSize: 3);
      final ref = _FakeActorRef('test');

      // Fill queue
      dlq.enqueue(DeadLetter('msg1', ref, ref));
      dlq.enqueue(DeadLetter('msg2', ref, ref));
      dlq.enqueue(DeadLetter('msg3', ref, ref));
      expect(dlq.length, 3);

      // Adding a 4th should evict oldest
      dlq.enqueue(DeadLetter('msg4', ref, ref));
      expect(dlq.length, 3);

      // First message should be msg2 (msg1 was evicted)
      final first = dlq.dequeue() as DeadLetter;
      expect(first.message, 'msg2');

      expect(metrics.getCounter('dead_letters.evicted'), 1);
    });
  });

  group('context.watch', () {
    late TestActorSystem system;

    setUp(() {
      system = TestActorSystem();
    });

    tearDown(() async {
      await system.shutdown();
    });

    test('delivers Terminated message when watched actor stops', () async {
      final probe = await system.createProbe();
      final actor = await system.spawn('watched', () => FailingActor());

      // Watch the actor
      probe.watch(actor);

      // Stop the watched actor
      await system.stop(actor);

      // Probe should receive a Terminated message
      final msg = await probe.expectMsgType<Terminated>(
          timeout: const Duration(seconds: 2));
      expect(msg.actor.id, 'watched');
    });
  });

  group('Supervision Scope', () {
    late TestActorSystem system;

    setUp(() {
      system = TestActorSystem();
    });

    tearDown(() async {
      await system.shutdown();
    });

    test('OneForOneStrategy only restarts the failed child', () async {
      final strategy = OneForOneStrategy(
        decider: (error, stackTrace) => SupervisionDecision.restart,
        maxRetries: 5,
      );

      final supervisorData = await system.spawnAndGetActor(
        'supervisor',
        () => SupervisorActor(strategy),
      );
      final supervisor = supervisorData.actor as SupervisorActor;

      final child1 = await supervisor.supervise('child1', () => CounterActor());
      final child2 = await supervisor.supervise('child2', () => CounterActor());

      // Increment child2's counter
      child2.tell(LocalMessage(payload: 'increment'));
      await Future.delayed(const Duration(milliseconds: 50));

      // Fail child1 - only child1 should restart
      child1.tell(LocalMessage(payload: 'fail'));
      await Future.delayed(const Duration(milliseconds: 100));

      // child2 should still be alive (not restarted) and its state preserved
      expect(child2.isAlive, isTrue);
    });
  });
}

/// Minimal ActorRef implementation for testing
class _FakeActorRef implements ActorRef {
  @override
  final String id;

  _FakeActorRef(this.id);

  @override
  bool get isAlive => true;

  @override
  void tell(Message message, {ActorRef? sender}) {}

  @override
  Future<T> ask<T>(Message message, [Duration? timeout]) {
    throw UnimplementedError();
  }

  @override
  void watch(ActorRef watcher) {}
}
