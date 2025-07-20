import 'package:dactor/dactor.dart';
import 'package:dactor/src/local_message.dart';
import 'package:dactor/src/metrics/metrics.dart';
import 'package:test/test.dart';

class TestActor extends Actor {
  @override
  Future<void> onMessage(message) async {
    if (message == 'hello') {
      context.sender?.tell(LocalMessage(payload: 'world'), sender: context.self);
    } else if (message == 'fail') {
      throw Exception('failed');
    }
  }
}

void main() {
  group('ActorSystem Metrics', () {
    late ActorSystem system;
    late InMemoryMetricsCollector metrics;

    setUp(() {
      metrics = InMemoryMetricsCollector();
      system = ActorSystem.create(ActorSystemConfig(metricsCollector: metrics));
    });

    tearDown(() async {
      await system.shutdown();
    });

    test('should increment spawned and active actors count', () async {
      expect(metrics.getCounter('actors.spawned'), 0);
      expect(metrics.getGauge('actors.active'), null);

      await system.spawn('test', () => TestActor());

      expect(metrics.getCounter('actors.spawned'), 1);
      expect(metrics.getGauge('actors.active'), 1);
    });

    test('should increment stopped and decrement active actors count', () async {
      final actor = await system.spawn('test', () => TestActor());
      expect(metrics.getGauge('actors.active'), 1);

      await system.stop(actor);

      expect(metrics.getCounter('actors.stopped'), 1);
      expect(metrics.getGauge('actors.active'), 0);
    });

    test('should increment processed messages count', () async {
      final actor = await system.spawn('test', () => TestActor());
      actor.tell(LocalMessage(payload: 'hello'));
      await Future.delayed(Duration(milliseconds: 100)); // Allow time for message processing
      expect(metrics.getCounter('messages.processed'), greaterThan(0));
    });

    test('should record message processing time', () async {
      final actor = await system.spawn('test', () => TestActor());
      actor.tell(LocalMessage(payload: 'hello'));
      await Future.delayed(Duration(milliseconds: 100));
      expect(metrics.getTimings('messages.processing_time'), isNotEmpty);
    });

    test('should increment failed actors count', () async {
      final actor = await system.spawn('test', () => TestActor());
      actor.tell(LocalMessage(payload: 'fail'));
      await Future.delayed(Duration(milliseconds: 100));
      expect(metrics.getCounter('actors.failed'), 1);
    });

    test('should increment system shutdown count', () async {
      await system.shutdown();
      expect(metrics.getCounter('system.shutdown'), 1);
    });

    test('should increment dead letters count', () async {
      final actor = await system.spawn('test', () => TestActor());
      await system.stop(actor);
      actor.tell(LocalMessage(payload: 'late message'));
      await Future.delayed(Duration(milliseconds: 100));
      expect(metrics.getCounter('dead_letters'), greaterThan(0));
    });

    test('should update mailbox size gauge', () async {
      final actor = await system.spawn('test', () => TestActor());
      actor.tell(LocalMessage(payload: 'message1'));
      actor.tell(LocalMessage(payload: 'message2'));
      await Future.delayed(Duration(milliseconds: 100));
      expect(metrics.getGauge('mailbox.size'), isNotNull);
    });
  });
}
