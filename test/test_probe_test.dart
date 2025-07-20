import 'package:dactor/dactor.dart';
import 'package:test/test.dart';

class EchoActor extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {
    // Echo back the received message to the sender
    context.sender?.tell(LocalMessage(payload: message));
  }
}

void main() {
  group('TestProbe', () {
    late TestActorSystem system;
    late TestProbe probe;

    setUp(() async {
      system = TestActorSystem();
      probe = await system.createProbe();
    });

    tearDown(() async {
      await system.shutdown();
    });

    test('should expect a message', () async {
      final echo = await system.spawn('echo', () => EchoActor());
      echo.tell(LocalMessage(payload: 'hello'), sender: probe.ref);
      await probe.expectMsg('hello');
    });

    test('should expect a message with timeout', () async {
      final echo = await system.spawn('echo', () => EchoActor());
      echo.tell(LocalMessage(payload: 'hello'), sender: probe.ref);
      await probe.expectMsg('hello', timeout: Duration(seconds: 1));
    });

    test('should expect a message of type', () async {
      final echo = await system.spawn('echo', () => EchoActor());
      echo.tell(LocalMessage(payload: 'hello'), sender: probe.ref);
      final msg = await probe.expectMsgType<String>();
      expect(msg, 'hello');
    });

    test('should expect a message of type with timeout', () async {
      final echo = await system.spawn('echo', () => EchoActor());
      echo.tell(LocalMessage(payload: 'hello'), sender: probe.ref);
      final msg = await probe.expectMsgType<String>(timeout: Duration(seconds: 1));
      expect(msg, 'hello');
    });

    test('should get the last message', () async {
      final echo = await system.spawn('echo', () => EchoActor());
      echo.tell(LocalMessage(payload: 'hello'), sender: probe.ref);
      await probe.expectMsg('hello');
      expect(probe.lastMessage, 'hello');
    });

    test('should reply to a message', () async {
      final echo = await system.spawn('echo', () => EchoActor());
      echo.tell(LocalMessage(payload: 'hello'), sender: probe.ref);
      await probe.expectMsg('hello');
      probe.reply('world');
      // This is not a great test, but it's hard to test a reply without another actor.
    });
  });
}
