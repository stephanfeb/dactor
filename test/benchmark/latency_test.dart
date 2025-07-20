import 'package:dactor/dactor.dart';
import 'package:test/test.dart';
import 'dart:async';

import 'package:dactor/src/local_actor_system.dart';
import 'package:dactor/src/local_message.dart';
import 'package:dactor/src/message.dart';
import 'package:dactor/src/routing/pool.dart';

class PingActor extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {
    if (message == 'ping') {
      context.sender!.tell(LocalMessage(payload: 'pong'));
    }
  }
}

void main() {
  group('Latency', () {
    late LocalActorSystem system;
    late ActorRef actor;

    setUp(() async {
      system = LocalActorSystem();
      actor = await system.spawn('ping', () => PingActor());
    });

    tearDown(() async {
      await system.shutdown();
    });

    test('measures latency for a single actor', () async {
      const messageCount = 10000;
      final stopwatch = Stopwatch();
      var totalLatency = 0;

      for (var i = 0; i < messageCount; i++) {
        stopwatch.start();
        await actor.ask(LocalMessage(payload: 'ping'), const Duration(seconds: 1));
        stopwatch.stop();
        totalLatency += stopwatch.elapsedMicroseconds;
        stopwatch.reset();
      }

      final avgLatency = totalLatency / messageCount;
      print('Single Actor - Average latency: ${avgLatency.toStringAsFixed(2)} us');
    });

    test('measures latency for a pooled actor', () async {
      final pool = Pool(workerCount: 4);
      final pooledActor = await system.spawn('pooled-ping', () => PingActor(), pool: pool);
      const messageCount = 10000;
      final stopwatch = Stopwatch();
      var totalLatency = 0;

      for (var i = 0; i < messageCount; i++) {
        stopwatch.start();
        await pooledActor.ask(LocalMessage(payload: 'ping'), const Duration(seconds: 1));
        stopwatch.stop();
        totalLatency += stopwatch.elapsedMicroseconds;
        stopwatch.reset();
      }

      final avgLatency = totalLatency / messageCount;
      print('Pooled Actor - Average latency: ${avgLatency.toStringAsFixed(2)} us');
    });
  });
}
