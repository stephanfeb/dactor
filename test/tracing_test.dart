import 'package:dactor/dactor.dart';
import 'package:dactor/spi.dart';
import 'support/probe.dart';
import 'package:test/test.dart';

class TestActor extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {
    if (message.toString() == 'hello') {
      context.sender?.tell('world');
    }
  }
}

void main() {
  group('Message Tracing', () {
    late TestActorSystem system;
    late InMemoryTraceCollector collector;

    setUp(() {
      collector = InMemoryTraceCollector();
      system = TestActorSystem(ActorSystemConfig(traceCollector: collector));
    });

    tearDown(() async {
      await system.shutdown();
    });

    test('should trace message flow', () async {
      final probe = await system.createProbe();
      final actor = await system.spawn('test', () => TestActor());

      sendAs(probe.ref, () => actor.tell('hello'));

      await Future.delayed(const Duration(milliseconds: 100));

      // One id ties the message's events together.
      final trace = collector.traces.values
          .singleWhere((events) => events.first.message == 'hello');
      expect(trace.length, 2);
      expect(trace[0].event, 'sent');
      expect(trace[1].event, 'processed');
    });
  });
}
