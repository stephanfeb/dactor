import 'package:dactor/dactor.dart';
import 'package:dactor/src/tracing/tracing.dart';
import 'package:dactor_test/dactor_test.dart';
import 'package:test/test.dart';

class TestActor extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {
    if (message.toString() == 'hello') {
      context.sender?.tell(LocalMessage(payload: 'world'));
    }
  }
}

void main() {
  group('Message Tracing', () {
    late TestActorSystem system;
    late InMemoryTraceCollector collector;

    setUp(() {
      collector = InMemoryTraceCollector();
      system =
          TestActorSystem(ActorSystemConfig(traceCollector: collector));
    });

    tearDown(() async {
      await system.shutdown();
    });

    test('should trace message flow', () async {
      final probe = await system.createProbe();
      final actor = await system.spawn('test', () => TestActor());

      final message = LocalMessage(payload: 'hello', sender: probe.ref);
      actor.tell(message);

      await Future.delayed(const Duration(milliseconds: 100));

      final trace = collector.traces[message.correlationId];
      expect(trace, isNotNull);
      expect(trace!.length, 2);
      expect(trace[0].event, 'sent');
      expect(trace[1].event, 'processed');
    });
  });
}
