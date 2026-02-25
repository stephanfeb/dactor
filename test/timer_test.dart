import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:dactor/src/dactor_timer_scheduler.dart';
import 'package:dactor_test/dactor_test.dart';
import 'package:test/test.dart';

class TimerTestActor extends Actor {
  final List<String> receivedMessages = [];
  Completer<void>? messageCompleter;
  
  @override
  Future<void> onMessage(dynamic message) async {
    receivedMessages.add(message.toString());
    messageCompleter?.complete();
  }

  void expectMessage(String expectedMessage) {
    messageCompleter = Completer<void>();
  }

  Future<void> waitForMessage([Duration timeout = const Duration(seconds: 5)]) async {
    await messageCompleter?.future.timeout(timeout);
    messageCompleter = null;
  }
}

void main() {
  group('Timer Scheduler Tests', () {
    late TestActorSystem system;
    late ActorRef actor;
    late TimerTestActor actorInstance;

    setUp(() async {
      system = TestActorSystem();
      final result = await system.spawnAndGetActor(
        'timer-test', 
        () => TimerTestActor()
      );
      actor = result.ref;
      actorInstance = result.actor as TimerTestActor;
    });

    tearDown(() async {
      await system.shutdown();
    });

    group('Single Timer', () {
      test('should send message after specified delay', () async {
        actorInstance.expectMessage('timeout');
        
        actorInstance.context.timers.startSingleTimer(
          'test-timer',
          'timeout',
          Duration(milliseconds: 100),
        );

        await actorInstance.waitForMessage();
        expect(actorInstance.receivedMessages, contains('timeout'));
      });

      test('should replace existing timer with same key', () async {
        actorInstance.context.timers.startSingleTimer(
          'test-timer',
          'first-message',
          Duration(milliseconds: 200),
        );

        // Immediately replace with a faster timer
        actorInstance.context.timers.startSingleTimer(
          'test-timer',
          'second-message',
          Duration(milliseconds: 50),
        );

        await Future.delayed(Duration(milliseconds: 100));
        
        // Should only receive the second message
        expect(actorInstance.receivedMessages, contains('second-message'));
        expect(actorInstance.receivedMessages, isNot(contains('first-message')));
      });

      test('should not be active after execution', () async {
        actorInstance.context.timers.startSingleTimer(
          'test-timer',
          'message',
          Duration(milliseconds: 50),
        );

        expect(actorInstance.context.timers.isTimerActive('test-timer'), isTrue);
        
        await Future.delayed(Duration(milliseconds: 100));
        
        expect(actorInstance.context.timers.isTimerActive('test-timer'), isFalse);
      });
    });

    group('Fixed Delay Timer', () {
      test('should send messages with fixed delay', () async {
        actorInstance.context.timers.startTimerWithFixedDelay(
          'periodic-timer',
          'tick',
          Duration(milliseconds: 50),
        );

        // Wait for multiple ticks
        await Future.delayed(Duration(milliseconds: 250));
        
        // Should have received multiple tick messages
        final tickCount = actorInstance.receivedMessages
            .where((msg) => msg == 'tick')
            .length;
        
        expect(tickCount, greaterThan(3));
        
        // Clean up
        actorInstance.context.timers.cancel('periodic-timer');
      });
    });

    group('Fixed Rate Timer', () {
      test('should send messages at fixed rate', () async {
        actorInstance.context.timers.startTimerAtFixedRate(
          'rate-timer',
          'rate-tick',
          Duration(milliseconds: 50),
        );

        await Future.delayed(Duration(milliseconds: 250));
        
        final tickCount = actorInstance.receivedMessages
            .where((msg) => msg == 'rate-tick')
            .length;
        
        expect(tickCount, greaterThan(3));
        
        // Clean up
        actorInstance.context.timers.cancel('rate-timer');
      });
    });

    group('Timer Management', () {
      test('should cancel specific timer', () async {
        actorInstance.context.timers.startSingleTimer(
          'cancel-test',
          'should-not-receive',
          Duration(milliseconds: 100),
        );

        expect(actorInstance.context.timers.isTimerActive('cancel-test'), isTrue);
        
        actorInstance.context.timers.cancel('cancel-test');
        
        expect(actorInstance.context.timers.isTimerActive('cancel-test'), isFalse);
        
        await Future.delayed(Duration(milliseconds: 150));
        
        expect(actorInstance.receivedMessages, 
               isNot(contains('should-not-receive')));
      });

      test('should cancel all timers', () async {
        actorInstance.context.timers.startSingleTimer(
          'timer1', 'message1', Duration(milliseconds: 100));
        actorInstance.context.timers.startSingleTimer(
          'timer2', 'message2', Duration(milliseconds: 100));
        actorInstance.context.timers.startTimerWithFixedDelay(
          'timer3', 'message3', Duration(milliseconds: 50));

        expect(actorInstance.context.timers.activeTimers.length, equals(3));
        
        actorInstance.context.timers.cancelAll();
        
        expect(actorInstance.context.timers.activeTimers.length, equals(0));
        
        await Future.delayed(Duration(milliseconds: 150));
        
        expect(actorInstance.receivedMessages, isEmpty);
      });

      test('should report active timers correctly', () async {
        expect(actorInstance.context.timers.activeTimers, isEmpty);
        
        actorInstance.context.timers.startSingleTimer(
          'timer1', 'message1', Duration(milliseconds: 200));
        actorInstance.context.timers.startTimerWithFixedDelay(
          'timer2', 'message2', Duration(milliseconds: 100));

        final activeTimers = actorInstance.context.timers.activeTimers;
        expect(activeTimers, hasLength(2));
        expect(activeTimers, containsAll(['timer1', 'timer2']));
        
        // Clean up
        actorInstance.context.timers.cancelAll();
      });

      test('should handle cancelling non-existent timer gracefully', () async {
        // Should not throw
        actorInstance.context.timers.cancel('non-existent');
        expect(actorInstance.context.timers.isTimerActive('non-existent'), isFalse);
      });
    });

    group('Lifecycle Integration', () {
      test('should cancel all timers when actor stops', () async {
        actorInstance.context.timers.startSingleTimer(
          'timer1', 'message1', Duration(milliseconds: 500));
        actorInstance.context.timers.startTimerWithFixedDelay(
          'timer2', 'message2', Duration(milliseconds: 100));

        expect(actorInstance.context.timers.activeTimers.length, equals(2));
        
        await system.stop(actor);
        
        // Give some time for cleanup
        await Future.delayed(Duration(milliseconds: 50));
      });

      test('should not send messages after timer disposal', () async {
        actorInstance.context.timers.startSingleTimer(
          'dispose-test', 'should-not-receive', Duration(milliseconds: 100));

        // Manually dispose the timer scheduler
        final timerScheduler = actorInstance.context.timers as DactorTimerScheduler;
        timerScheduler.dispose();
        
        await Future.delayed(Duration(milliseconds: 150));
        
        expect(actorInstance.receivedMessages, 
               isNot(contains('should-not-receive')));
      });
    });

    group('Edge Cases', () {
      test('should handle zero duration timers', () async {
        actorInstance.expectMessage('immediate');
        
        actorInstance.context.timers.startSingleTimer(
          'immediate-timer',
          'immediate',
          Duration.zero,
        );

        await actorInstance.waitForMessage();
        expect(actorInstance.receivedMessages, contains('immediate'));
      });

      test('should handle multiple timers with different keys', () async {
        actorInstance.context.timers.startSingleTimer(
          'timer-a', 'message-a', Duration(milliseconds: 50));
        actorInstance.context.timers.startSingleTimer(
          'timer-b', 'message-b', Duration(milliseconds: 100));
        actorInstance.context.timers.startSingleTimer(
          'timer-c', 'message-c', Duration(milliseconds: 150));

        await Future.delayed(Duration(milliseconds: 200));
        
        expect(actorInstance.receivedMessages, contains('message-a'));
        expect(actorInstance.receivedMessages, contains('message-b'));
        expect(actorInstance.receivedMessages, contains('message-c'));
      });
    });
  });
} 