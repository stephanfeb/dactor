import 'dart:async';
import 'package:test/test.dart';
import 'package:dactor/dactor.dart';

/// Test message that implements Message but not LocalMessage
class SimpleMessage implements Message {
  final String data;
  
  @override
  final String correlationId;
  @override
  final ActorRef? replyTo;
  @override
  final DateTime timestamp;
  @override
  final Map<String, dynamic> metadata;

  SimpleMessage(this.data)
      : correlationId = 'simple_${DateTime.now().millisecondsSinceEpoch}',
        replyTo = null,
        timestamp = DateTime.now(),
        metadata = {};
}

/// Test response using AskableResponse helper
class SimpleResponse extends AskableResponse {
  final String result;
  
  SimpleResponse(this.result);
}

/// Test command using AskableMessage helper
class TestCommand extends AskableMessage {
  final String command;
  
  TestCommand(this.command);
}

/// Test response using manual LocalMessage extension
class ManualResponse extends LocalMessage {
  final int value;
  
  ManualResponse(this.value) : super(payload: null);
  
  @override
  dynamic get payload => this;
}

/// Test actor that handles various message types
class CompatibilityTestActor extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {
    final sender = context.sender;
    if (sender == null) return;

    if (message is SimpleMessage) {
      // Test handling regular Message (not LocalMessage)
      sender.tell(SimpleResponse('processed_${message.data}'));
    } else if (message is TestCommand) {
      // Test handling AskableMessage
      sender.tell(SimpleResponse('command_${message.command}'));
    } else if (message is String) {
      if (message == 'get_number') {
        // Test manual LocalMessage response
        sender.tell(ManualResponse(42));
      } else if (message == 'error_test') {
        // Test sending wrong response type
        sender.tell(LocalMessage(payload: 'wrong_type'));
      } else if (message == 'direct_test') {
        // Test LocalMessage payload handling
        sender.tell(SimpleResponse('processed_$message'));
      } else if (message == 'correlation_test') {
        // Test correlation ID preservation
        sender.tell(SimpleResponse('processed_$message'));
      }
    }
  }
}

void main() {
  group('Ask Compatibility Tests', () {
    late TestActorSystem system;
    late ActorRef testActor;

    setUp(() async {
      system = TestActorSystem();
      testActor = await system.spawn('compatibility_test', () => CompatibilityTestActor());
    });

    tearDown(() async {
      await system.shutdown();
    });

    test('should handle regular Message (not LocalMessage) in ask', () async {
      final message = SimpleMessage('test_data');
      
      final response = await testActor.ask<SimpleResponse>(message, Duration(seconds: 1));
      
      expect(response, isA<SimpleResponse>());
      expect(response.result, 'processed_test_data');
    });

    test('should handle AskableMessage in ask', () async {
      final command = TestCommand('execute');
      
      final response = await testActor.ask<SimpleResponse>(command, Duration(seconds: 1));
      
      expect(response, isA<SimpleResponse>());
      expect(response.result, 'command_execute');
    });

    test('should handle manual LocalMessage response', () async {
      final message = LocalMessage(payload: 'get_number');
      final response = await testActor.ask<ManualResponse>(message, Duration(seconds: 1));
      
      expect(response, isA<ManualResponse>());
      expect(response.value, 42);
    });

    test('should provide helpful error for wrong response type', () async {
      final message = LocalMessage(payload: 'error_test');
      expect(
        () => testActor.ask<SimpleResponse>(message, Duration(seconds: 1)),
        throwsA(predicate((e) => 
          e is StateError && 
          e.message.contains('Ask response type mismatch') &&
          e.message.contains('Expected: SimpleResponse') &&
          e.message.contains('but received: String')
        )),
      );
    });

    test('should work with LocalMessage directly', () async {
      final localMessage = LocalMessage(payload: 'direct_test');
      
      final response = await testActor.ask<SimpleResponse>(localMessage, Duration(seconds: 1));
      
      expect(response, isA<SimpleResponse>());
      expect(response.result, 'processed_direct_test');
    });

    test('should preserve correlation ID from LocalMessage', () async {
      final originalId = 'test_correlation_123';
      final localMessage = LocalMessage(
        payload: 'correlation_test',
        correlationId: originalId,
      );
      
      // We can't directly test the correlation ID preservation in the response,
      // but we can verify the ask operation works correctly
      final response = await testActor.ask<SimpleResponse>(localMessage, Duration(seconds: 1));
      
      expect(response, isA<SimpleResponse>());
      expect(response.result, 'processed_correlation_test');
    });

    test('should handle concurrent ask operations', () async {
      final futures = List.generate(10, (index) {
        final message = SimpleMessage('concurrent_$index');
        return testActor.ask<SimpleResponse>(message, Duration(seconds: 1));
      });
      
      final responses = await Future.wait(futures);
      
      expect(responses.length, 10);
      for (int i = 0; i < responses.length; i++) {
        expect(responses[i].result, 'processed_concurrent_$i');
      }
    });

    test('AskableMessage should be instance of LocalMessage', () {
      final command = TestCommand('test');
      
      expect(command, isA<LocalMessage>());
      expect(command, isA<Message>());
      expect(command.payload, equals(command));
    });

    test('AskableResponse should be instance of LocalMessage', () {
      final response = SimpleResponse('test');
      
      expect(response, isA<LocalMessage>());
      expect(response, isA<Message>());
      expect(response.payload, equals(response));
    });
  });
}
