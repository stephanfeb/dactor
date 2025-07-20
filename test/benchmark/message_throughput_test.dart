import 'package:dactor/dactor.dart';
import 'package:test/test.dart';
import 'dart:async';

import 'package:dactor/src/local_actor_system.dart';
import 'package:dactor/src/local_message.dart';
import 'package:dactor/src/message.dart';
import 'package:dactor/src/routing/pool.dart';

class BenchmarkActor extends Actor {
  int count = 0;

  @override
  Future<void> onMessage(dynamic message) async {
    if (message == 'get_count') {
      context.sender!.tell(LocalMessage(payload: count));
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
        actor.tell(LocalMessage(payload: i));
      }

      final count = await actor.ask(LocalMessage(payload: 'get_count'), const Duration(seconds: 5));
      expect(count, messageCount);

      stopwatch.stop();
      final elapsed = stopwatch.elapsedMilliseconds;
      final throughput = messageCount / (elapsed / 1000);

      print('Single Actor - Processed $messageCount messages in ${elapsed}ms');
      print('Single Actor - Throughput: ${throughput.toStringAsFixed(2)} msg/sec');
    });

    test('measures message throughput for a pooled actor', () async {
      final pool = Pool(workerCount: 4);
      final pooledActor = await system.spawn('pooled-benchmark', () => BenchmarkActor(), pool: pool);
      const messageCount = 100000;
      final stopwatch = Stopwatch()..start();

      for (var i = 0; i < messageCount; i++) {
        pooledActor.tell(LocalMessage(payload: i));
      }

      // Wait for all messages to be processed
      await Future.delayed(const Duration(seconds: 2));

      stopwatch.stop();
      final elapsed = stopwatch.elapsedMilliseconds;
      final throughput = messageCount / (elapsed / 1000);

      print('Pooled Actor - Processed $messageCount messages in ${elapsed}ms');
      print('Pooled Actor - Throughput: ${throughput.toStringAsFixed(2)} msg/sec');
    });
  });
}
