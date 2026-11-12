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
  });
}
