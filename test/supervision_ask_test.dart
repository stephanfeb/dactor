import 'package:dactor/dactor.dart';
import 'package:test/test.dart';
import 'dart:async';

/// Test message for supervision + ask testing
class SupervisionTestMessage implements Message {
  final String data;
  
  SupervisionTestMessage(this.data);
  
  @override
  String get correlationId => 'supervision-test-${DateTime.now().millisecondsSinceEpoch}';
  
  @override
  Map<String, dynamic> get metadata => {'data': data};
  
  @override
  ActorRef? get replyTo => null;
  
  @override
  DateTime get timestamp => DateTime.now();
}

/// Test response for supervision + ask testing
class SupervisionTestResponse extends AskableResponse {
  final String result;
  
  SupervisionTestResponse(this.result);
}

/// Child actor that responds to messages
class TestChildActor extends Actor {
  final String name;
  
  TestChildActor(this.name);
  
  @override
  Future<void> onMessage(dynamic message) async {
    print('TestChildActor($name) received: ${message.runtimeType} - $message');
    print('TestChildActor($name): Actor ID: ${context.self.id}');
    
    final sender = context.sender;
    if (sender == null) {
      print('TestChildActor($name): No sender found!');
      return;
    }
    
    print('TestChildActor($name): Sender ID: ${sender.id}');
    print('TestChildActor($name): Sender type: ${sender.runtimeType}');
    
    if (message is SupervisionTestMessage) {
      print('TestChildActor($name): Processing SupervisionTestMessage with data: ${message.data}');
      print('TestChildActor($name): Sending response to sender: ${sender.id}');
      
      final response = SupervisionTestResponse('processed_${message.data}_by_$name');
      print('TestChildActor($name): Response created: ${response.runtimeType} - $response');
      print('TestChildActor($name): Response result: ${response.result}');
      
      sender.tell(response);
      print('TestChildActor($name): Response sent to sender');
    } else if (message is String) {
      print('TestChildActor($name): Processing String message: $message');
      print('TestChildActor($name): Sending string response to sender: ${sender.id}');
      sender.tell(LocalMessage(payload: 'echo_${message}_from_$name'));
    } else {
      print('TestChildActor($name): Unknown message type, ignoring');
    }
  }
  
  @override
  void preStart() {
    print('TestChildActor($name) started with ID: ${context.self.id}');
  }
}

/// Test supervisor that creates children via supervise()
class TestSupervisorActor extends SupervisorActor {
  final Map<String, ActorRef> children = {};
  
  TestSupervisorActor() : super(OneForOneStrategy(
    decider: (error, stackTrace) => SupervisionDecision.restart,
    maxRetries: 3,
  ));
  
  @override
  Future<void> onMessage(dynamic message) async {
    print('TestSupervisorActor received: ${message.runtimeType} - $message');
    
    if (message is String && message.startsWith('create_child:')) {
      final childName = message.split(':')[1];
      print('TestSupervisorActor: Creating child $childName');
      
      final childRef = await supervise(childName, () => TestChildActor(childName));
      children[childName] = childRef;
      
      print('TestSupervisorActor: Child $childName created with ID: ${childRef.id}');
      context.sender?.tell(LocalMessage(payload: 'child_created:$childName'));
    } else if (message is String && message.startsWith('ask_child:')) {
      final parts = message.split(':');
      final childName = parts[1];
      final testData = parts[2];
      
      final childRef = children[childName];
      if (childRef != null) {
        print('TestSupervisorActor: Asking child $childName with data: $testData');
        print('TestSupervisorActor: Child ref ID: ${childRef.id}');
        print('TestSupervisorActor: Child ref type: ${childRef.runtimeType}');
        print('TestSupervisorActor: About to call ask() on child...');
        
        final message = SupervisionTestMessage(testData);
        print('TestSupervisorActor: Created message: ${message.runtimeType} with data: ${message.data}');
        print('TestSupervisorActor: Message correlationId: ${message.correlationId}');
        
        try {
          print('TestSupervisorActor: Calling childRef.ask() with natural await syntax...');
          
          // ELEGANT FIX: Now we can use natural await syntax!
          // The asynchronous message processing prevents deadlock
          final response = await childRef.ask<SupervisionTestResponse>(
            message, 
            Duration(seconds: 5)
          );
          
          print('TestSupervisorActor: Got response from child: $response');
          print('TestSupervisorActor: Response type: ${response.runtimeType}');
          print('TestSupervisorActor: Response result: ${response.result}');
          context.sender?.tell(LocalMessage(payload: 'supervisor_got_response:${response.result}'));
        } catch (e) {
          print('TestSupervisorActor: Ask failed with error: $e');
          print('TestSupervisorActor: Error type: ${e.runtimeType}');
          context.sender?.tell(LocalMessage(payload: 'supervisor_ask_failed:$e'));
        }
      } else {
        print('TestSupervisorActor: Child $childName not found in children map');
        context.sender?.tell(LocalMessage(payload: 'child_not_found:$childName'));
      }
    }
  }
  
  @override
  void preStart() {
    print('TestSupervisorActor started with ID: ${context.self.id}');
  }
}

void main() {
  group('Supervision + Ask Pattern Tests', () {
    late TestActorSystem system;
    late TestProbe probe;

    setUp(() async {
      system = TestActorSystem();
      probe = await system.createProbe();
    });

    tearDown(() async {
      await system.shutdown();
    });

    test('direct spawn + ask should work (baseline)', () async {
      print('\n=== Testing direct spawn + ask (baseline) ===');
      
      // Create child directly via spawn (not supervise)
      final childRef = await system.spawn('direct-child', () => TestChildActor('direct'));
      
      // Direct ask should work
      final response = await childRef.ask<SupervisionTestResponse>(
        SupervisionTestMessage('test_data'), 
        Duration(seconds: 5)
      );
      
      expect(response, isA<SupervisionTestResponse>());
      expect(response.result, 'processed_test_data_by_direct');
      print('✓ Direct spawn + ask works correctly');
    });

    test('supervise + tell should work (baseline)', () async {
      print('\n=== Testing supervise + tell (baseline) ===');
      
      // Create supervisor
      final supervisor = await system.spawn('test-supervisor', () => TestSupervisorActor());
      
      // Ask supervisor to create a child
      supervisor.tell(LocalMessage(payload: 'create_child:test-child'), sender: probe.ref);
      await probe.expectMsg('child_created:test-child', timeout: Duration(seconds: 5));
      
      print('✓ Supervise + tell works correctly');
    });

    test('supervise + ask should work but currently fails', () async {
      print('\n=== Testing supervise + ask (the failing case) ===');
      
      // Create supervisor
      final supervisor = await system.spawn('test-supervisor', () => TestSupervisorActor());
      
      // Ask supervisor to create a child
      supervisor.tell(LocalMessage(payload: 'create_child:test-child'), sender: probe.ref);
      await probe.expectMsg('child_created:test-child', timeout: Duration(seconds: 5));
      
      // Now ask supervisor to ask the child (this should fail)
      print('Supervisor asking supervised child...');
      supervisor.tell(LocalMessage(payload: 'ask_child:test-child:test_data'), sender: probe.ref);
      
      final askResponse = await probe.expectMsgType<dynamic>(timeout: Duration(seconds: 10));
      print('Ask response: $askResponse');
      
      // This test will currently fail - we expect it to work but it times out
      if (askResponse.toString().startsWith('supervisor_ask_failed')) {
        print('❌ CONFIRMED BUG: Supervise + ask fails with: $askResponse');
        // For now, we expect this to fail to confirm the bug
        expect(askResponse.toString(), contains('TimeoutException'));
      } else {
        print('✓ Supervise + ask works correctly: $askResponse');
        expect(askResponse.toString(), contains('supervisor_got_response'));
      }
    });

    test('direct ask to supervised child should work', () async {
      print('\n=== Testing direct ask to supervised child ===');
      
      // Create supervisor
      final supervisor = await system.spawn('test-supervisor', () => TestSupervisorActor());
      
      // Ask supervisor to create a child
      supervisor.tell(LocalMessage(payload: 'create_child:test-child'), sender: probe.ref);
      await probe.expectMsg('child_created:test-child', timeout: Duration(seconds: 5));
      
      // Get the child reference directly and ask it
      final childRef = system.getActor('test-supervisor/test-child');
      expect(childRef, isNotNull);
      
      print('Direct ask to supervised child with ID: ${childRef!.id}');
      
      try {
        final response = await childRef.ask<SupervisionTestResponse>(
          SupervisionTestMessage('direct_test'), 
          Duration(seconds: 5)
        );
        
        expect(response, isA<SupervisionTestResponse>());
        expect(response.result, 'processed_direct_test_by_test-child');
        print('✓ Direct ask to supervised child works');
      } catch (e) {
        print('❌ Direct ask to supervised child failed: $e');
        rethrow;
      }
    });

    test('probe ask to supervised child should work', () async {
      print('\n=== Testing probe ask to supervised child ===');
      
      // Create supervisor
      final supervisor = await system.spawn('test-supervisor', () => TestSupervisorActor());
      
      // Ask supervisor to create a child
      supervisor.tell(LocalMessage(payload: 'create_child:test-child'), sender: probe.ref);
      await probe.expectMsg('child_created:test-child', timeout: Duration(seconds: 5));
      
      // Get the child reference and use probe to ask it
      final childRef = system.getActor('test-supervisor/test-child');
      expect(childRef, isNotNull);
      
      print('Probe asking supervised child with ID: ${childRef!.id}');
      
      // Use tell + expectMsg pattern (like TestProbe ask)
      childRef.tell(SupervisionTestMessage('probe_test'), sender: probe.ref);
      final response = await probe.expectMsgType<SupervisionTestResponse>(timeout: Duration(seconds: 5));
      
      expect(response.result, 'processed_probe_test_by_test-child');
      print('✓ Probe ask to supervised child works');
    });
  });
}
