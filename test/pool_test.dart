import 'package:dactor/dactor.dart';
import 'package:dactor/spi.dart';
import 'support/probe.dart';
import 'package:test/test.dart';

class Worker extends Actor {
  @override
  Future<void> onMessage(message) async {
    context.sender?.tell(message);
  }
}

/// Answers with the id of the worker that handled the message.
class WhoAmI extends Actor {
  @override
  Future<void> onMessage(message) async {
    context.sender?.tell(context.self.id);
  }
}

/// Sends everything to the last worker.
class LastWorker extends RoutingLogic {
  @override
  int select(int routeeCount, Object? message) => routeeCount - 1;
}

void main() {
  group('Actor Pool', () {
    late LocalActorSystem system;

    setUp(() {
      system = LocalActorSystem();
    });

    tearDown(() async {
      await system.shutdown();
    });

    test('should distribute messages to workers in a round-robin fashion',
        () async {
      final probe = TestProbe();
      final probeRef = await system.spawn('probe', () => probe);
      final router = await system.spawn(
        'worker-router',
        () => Worker(),
        pool: Pool(workerCount: 2),
      );

      sendAs(probeRef, () => router.tell('message1'));
      sendAs(probeRef, () => router.tell('message2'));
      sendAs(probeRef, () => router.tell('message3'));
      sendAs(probeRef, () => router.tell('message4'));

      await probe.expectMsg('message1');
      await probe.expectMsg('message2');
      await probe.expectMsg('message3');
      await probe.expectMsg('message4');
    });

    test('uses the pool\'s routing logic', () async {
      final pool = await system.spawn('p', () => WhoAmI(),
          pool: Pool(workerCount: 3, logic: LastWorker()));
      for (var i = 0; i < 3; i++) {
        expect(await pool.ask<String>('who'), 'p/worker-2');
      }
    });

    test('ask goes to the workers in turn', () async {
      final pool =
          await system.spawn('p', () => WhoAmI(), pool: Pool(workerCount: 2));
      expect([for (var i = 0; i < 4; i++) await pool.ask<String>('who')],
          ['p/worker-0', 'p/worker-1', 'p/worker-0', 'p/worker-1']);
    });

    test('a suspended pool holds messages, in order, until resumed', () async {
      final probe = TestProbe();
      final probeRef = await system.spawn('probe', () => probe);
      final pool =
          await system.spawn('p', () => Worker(), pool: Pool(workerCount: 2));
      system.sys.suspend(pool);
      sendAs(probeRef, () => pool.tell('m1'));
      sendAs(probeRef, () => pool.tell('m2'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(probe.lastMessage, isNull);

      final got = [probe.expectMsg('m1'), probe.expectMsg('m2')];
      system.sys.resume(pool);
      sendAs(probeRef, () => pool.tell('m3'));
      await Future.wait(got);
      await probe.expectMsg('m3');
    });

    test('a stopped pool sends to the dead letters', () async {
      final pool =
          await system.spawn('p', () => Worker(), pool: Pool(workerCount: 2));
      await system.stop(pool);
      pool.tell('late');
      expect(system.deadLetterQueue.length, 1);
    });
  });
}
