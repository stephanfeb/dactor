import 'package:dactor/dactor.dart';
import 'package:dactor_test/dactor_test.dart';
import 'package:test/test.dart';
import 'dart:async';

// Actor that simulates timeouts by not responding
class TimeoutActor extends Actor {
  bool _shouldTimeout = false;

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is SetShouldTimeout) {
      _shouldTimeout = message.shouldTimeout;
      context.sender?.tell(LocalMessage(payload: 'timeout_config_set'));
      return;
    }
    
    if (message is String && message == 'ping') {
      // Simulate timeout by not responding
      if (_shouldTimeout) {
        return; // Don't send a response
      }
      
      // Success case
      context.sender?.tell(LocalMessage(payload: 'pong'));
    }
  }
}

// Actor that always responds successfully
class EchoActor extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {
    context.sender?.tell(LocalMessage(payload: 'echo: $message'));
  }
}

class SetShouldTimeout {
  final bool shouldTimeout;
  SetShouldTimeout(this.shouldTimeout);
}

void main() {
  group('Enhanced Ask Pattern', () {
    late TestActorSystem system;

    setUp(() async {
      system = TestActorSystem();
    });

    tearDown(() async {
      await system.shutdown();
    });

    test('should use default timeout from AskConfig', () async {
      final config = ActorSystemConfig(
        askConfig: AskConfig(
          defaultTimeout: Duration(milliseconds: 100),
          enableRetries: false, // Disable retries for this test
        ),
      );
      final testSystem = TestActorSystem(config);
      final testActor = await testSystem.spawn('timeout_test', () => TimeoutActor());
      
      // Configure actor to timeout (not respond)
      await testActor.ask(LocalMessage(payload: SetShouldTimeout(true)), Duration(seconds: 1));
      
      final stopwatch = Stopwatch()..start();
      
      try {
        await testActor.ask(LocalMessage(payload: 'ping')); // Use default timeout
        fail('Should have timed out');
      } catch (e) {
        expect(e, isA<TimeoutException>());
        stopwatch.stop();
        // Should be close to 100ms (with some tolerance for processing time)
        expect(stopwatch.elapsedMilliseconds, greaterThan(80));
        expect(stopwatch.elapsedMilliseconds, lessThan(300));
      }
      
      await testSystem.shutdown();
    });

    test('should retry on timeout with exponential backoff', () async {
      final config = ActorSystemConfig(
        askConfig: AskConfig(
          defaultTimeout: Duration(milliseconds: 50),
          maxRetries: 2,
          retryBackoffBase: Duration(milliseconds: 10),
          retryBackoffMultiplier: 2.0,
        ),
      );
      final testSystem = TestActorSystem(config);
      final testActor = await testSystem.spawn('retry_test', () => TimeoutActor());
      
      // Configure actor to timeout
      await testActor.ask(LocalMessage(payload: SetShouldTimeout(true)), Duration(seconds: 1));
      
      final stopwatch = Stopwatch()..start();
      
      try {
        await testActor.ask(LocalMessage(payload: 'ping'));
        fail('Should have timed out after retries');
      } catch (e) {
        expect(e, isA<TimeoutException>());
        stopwatch.stop();
        
        // Should take approximately: 50ms (initial) + 10ms (backoff) + 50ms (retry1) + 20ms (backoff) + 50ms (retry2)
        // = ~180ms total, but allow for some variation
        expect(stopwatch.elapsedMilliseconds, greaterThan(140));
        expect(stopwatch.elapsedMilliseconds, lessThan(600));
      }
      
      await testSystem.shutdown();
    });

    test('should succeed when actor responds normally', () async {
      final config = ActorSystemConfig(
        askConfig: AskConfig(defaultTimeout: Duration(seconds: 1)),
      );
      final testSystem = TestActorSystem(config);
      final testActor = await testSystem.spawn('success_test', () => EchoActor());
      
      final result = await testActor.ask(LocalMessage(payload: 'hello'));
      expect(result, 'echo: hello');
      
      await testSystem.shutdown();
    });

    test('should respect retries disabled configuration', () async {
      final config = ActorSystemConfig(
        askConfig: AskConfig.noRetries(),
      );
      final testSystem = TestActorSystem(config);
      final testActor = await testSystem.spawn('no_retry_test', () => TimeoutActor());
      
      // Configure actor to timeout
      await testActor.ask(LocalMessage(payload: SetShouldTimeout(true)), Duration(seconds: 1));
      
      final stopwatch = Stopwatch()..start();
      
      try {
        await testActor.ask(LocalMessage(payload: 'ping'), Duration(milliseconds: 100));
        fail('Should have timed out');
      } catch (e) {
        expect(e, isA<TimeoutException>());
        stopwatch.stop();
        
        // Should fail quickly without retries (around 100ms)
        expect(stopwatch.elapsedMilliseconds, lessThan(200));
      }
      
      await testSystem.shutdown();
    });

    test('should calculate correct exponential backoff', () {
      final config = AskConfig(
        retryBackoffBase: Duration(milliseconds: 100),
        retryBackoffMultiplier: 2.0,
        maxBackoffDuration: Duration(seconds: 5),
      );

      expect(config.calculateBackoff(1), Duration(milliseconds: 100));
      expect(config.calculateBackoff(2), Duration(milliseconds: 200));
      expect(config.calculateBackoff(3), Duration(milliseconds: 400));
      expect(config.calculateBackoff(4), Duration(milliseconds: 800));
      
      // Should cap at maxBackoffDuration
      expect(config.calculateBackoff(10), Duration(seconds: 5));
    });

    test('should use development configuration correctly', () {
      final config = AskConfig.development();
      
      expect(config.defaultTimeout, Duration(seconds: 30));
      expect(config.maxRetries, 5);
      expect(config.enableRetries, true);
    });

    test('should use production configuration correctly', () {
      final config = AskConfig.production();
      
      expect(config.defaultTimeout, Duration(seconds: 3));
      expect(config.maxRetries, 2);
      expect(config.enableRetries, true);
    });

    test('askWithRetry should allow overriding config parameters', () async {
      final config = ActorSystemConfig(
        askConfig: AskConfig(maxRetries: 1),
      );
      final testSystem = TestActorSystem(config);
      final testActor = await testSystem.spawn('override_test', () => EchoActor());
      
      // Test that we can override timeout
      final localRef = testActor as LocalActorRef;
      final result = await localRef.askWithRetry(
        LocalMessage(payload: 'test'),
        timeout: Duration(seconds: 2),
      );
      
      expect(result, 'echo: test');
      
      await testSystem.shutdown();
    });

    test('should provide detailed error messages with attempt information', () async {
      final config = ActorSystemConfig(
        askConfig: AskConfig(
          defaultTimeout: Duration(milliseconds: 50),
          maxRetries: 0, // No retries
        ),
      );
      final testSystem = TestActorSystem(config);
      final testActor = await testSystem.spawn('error_message_test', () => TimeoutActor());
      
      // Configure actor to timeout
      await testActor.ask(LocalMessage(payload: SetShouldTimeout(true)), Duration(seconds: 1));
      
      try {
        await testActor.ask(LocalMessage(payload: 'ping'));
        fail('Should have timed out');
      } catch (e) {
        expect(e, isA<TimeoutException>());
        expect(e.toString(), contains('timed out after 50ms'));
        expect(e.toString(), contains('attempt 1'));
        expect(e.toString(), contains('error_message_test')); // Actor ID should be in error
      }
      
      await testSystem.shutdown();
    });
  });
} 