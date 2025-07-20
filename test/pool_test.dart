import 'package:dactor/dactor.dart';
import 'package:dactor/src/actor.dart';
import 'package:dactor/src/local_actor_system.dart';
import 'package:dactor/src/local_message.dart';
import 'package:dactor/src/routing/pool.dart';
import 'package:test/test.dart';

class Worker extends Actor {
  @override
  Future<void> onMessage(message) async {
    context.sender?.tell(LocalMessage(payload: message));
  }
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

      router.tell(LocalMessage(payload: 'message1'), sender: probeRef);
      router.tell(LocalMessage(payload: 'message2'), sender: probeRef);
      router.tell(LocalMessage(payload: 'message3'), sender: probeRef);
      router.tell(LocalMessage(payload: 'message4'), sender: probeRef);

      await probe.expectMsg('message1');
      await probe.expectMsg('message2');
      await probe.expectMsg('message3');
      await probe.expectMsg('message4');
    });
  });
}
