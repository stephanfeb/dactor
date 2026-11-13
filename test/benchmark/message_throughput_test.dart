import 'package:dactor/dactor.dart';
import 'package:test/test.dart';
import 'dart:async';

class BenchmarkActor extends Actor {
  int count = 0;

  @override
  Future<void> onMessage(dynamic message) async {
    if (message == 'get_count') {
      context.sender!.tell(count);
    } else {
      count++;
    }
  }
}

void main() {
  group('Message Throughput', () {
    late LocalActorSystem system;
    late ActorRef actor;

    setUp(() async {
      system = LocalActorSystem();
      actor = await system.spawn('benchmark', () => BenchmarkActor());
    });

    tearDown(() async {
      await system.shutdown();
    });

    test('measures message throughput for a single actor', () async {
      const messageCount = 100000;
      final stopwatch = Stopwatch()..start();

      for (var i = 0; i < messageCount; i++) {
        actor.tell(i);
      }

      final count = await actor.ask('get_count', const Duration(seconds: 5));
      expect(count, messageCount);

      stopwatch.stop();
      final elapsed = stopwatch.elapsedMilliseconds;
      final throughput = messageCount / (elapsed / 1000);

      print('Single Actor - Processed $messageCount messages in ${elapsed}ms');
      print(
          'Single Actor - Throughput: ${throughput.toStringAsFixed(2)} msg/sec');
    });

    test('measures message throughput for a pooled actor', () async {
      const messageCount = 100000;
      final done = Completer<void>();
      var handled = 0;
      final pooledActor = await system.spawn(
          'pooled-benchmark',
          () => _Counting(() {
                if (++handled == messageCount) done.complete();
              }),
          pool: Pool(workerCount: 4));
      final stopwatch = Stopwatch()..start();

      for (var i = 0; i < messageCount; i++) {
        pooledActor.tell(i);
      }
      await done.future.timeout(const Duration(seconds: 5));

      stopwatch.stop();
      final elapsed = stopwatch.elapsedMilliseconds;
      final throughput = messageCount / (elapsed / 1000);

      print('Pooled Actor - Processed $messageCount messages in ${elapsed}ms');
      print(
          'Pooled Actor - Throughput: ${throughput.toStringAsFixed(2)} msg/sec');
    });
  });
}

/// Calls [onHandled] for every message.
class _Counting extends Actor {
  final void Function() onHandled;
  _Counting(this.onHandled);

  @override
  Future<void> onMessage(dynamic message) async => onHandled();
}
