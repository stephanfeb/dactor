import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:test/test.dart';

class _TickerActor extends Actor {
  final List<String> events;
  int ticks = 0;

  _TickerActor(this.events);

  @override
  FutureOr<void> preStart() {
    events.add('preStart');
    context.timers
        .startTimerAtFixedRate('tick', 'tick', const Duration(milliseconds: 5));
  }

  @override
  Future<void> onMessage(dynamic message) async {
    if (message == 'tick') ticks++;
  }

  @override
  void postStop() {
    events.add('postStop');
  }
}

class _ParentActor extends Actor {
  final List<String> order;
  _ParentActor(this.order);

  @override
  Future<void> preStart() async {
    await context.spawn('${context.self.id}/child', () => _ChildActor(order));
  }

  @override
  Future<void> onMessage(dynamic message) async {}

  @override
  void postStop() => order.add('parent');
}

class _ChildActor extends Actor {
  final List<String> order;
  _ChildActor(this.order);

  @override
  Future<void> onMessage(dynamic message) async {}

  @override
  void postStop() => order.add('child');
}

void main() {
  group('LocalActorSystem.shutdown', () {
    test('runs postStop, kills refs and cancels timers for every actor',
        () async {
      final system = LocalActorSystem();
      final events = <String>[];
      final spawned =
          await system.spawnAndGetActor('ticker', () => _TickerActor(events));
      final actor = spawned.actor as _TickerActor;
      final ref = spawned.ref;

      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(actor.ticks, greaterThan(0),
          reason: 'timer should be delivering before shutdown');
      expect(ref.isAlive, isTrue);

      await system.shutdown();

      expect(events, ['preStart', 'postStop']);
      expect(ref.isAlive, isFalse);
      expect(actor.context.timers.isTimerActive('tick'), isFalse);
      expect(actor.context.timers.activeTimers, isEmpty);
      expect(system.getActor('ticker'), isNull);

      // No tick may be delivered after shutdown.
      final ticksAtShutdown = actor.ticks;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(actor.ticks, ticksAtShutdown);
    });

    test('messages sent after shutdown become dead letters', () async {
      final system = LocalActorSystem();
      final ref = await system.spawn('a', () => _TickerActor([]));
      await system.shutdown();

      ref.tell('late');

      expect(system.deadLetterQueue.length, 1);
      final letter = system.deadLetterQueue.dequeue();
      expect(letter, isA<DeadLetter>());
      expect((letter as DeadLetter).recipient.id, 'a');
    });

    test('stops children before their parents', () async {
      final system = LocalActorSystem();
      final order = <String>[];
      await system.spawn('parent', () => _ParentActor(order));
      expect(system.getActor('parent/child'), isNotNull);

      await system.shutdown();

      expect(order, ['child', 'parent']);
      expect(system.getActor('parent/child'), isNull);
    });

    test('is idempotent and stop() after shutdown is a no-op', () async {
      final system = LocalActorSystem(
          ActorSystemConfig(metricsCollector: InMemoryMetricsCollector()));
      final events = <String>[];
      final ref = await system.spawn('a', () => _TickerActor(events));

      await system.shutdown();
      await system.shutdown();
      await system.stop(ref);

      expect(events.where((e) => e == 'postStop').length, 1);
      expect(
          (system.metrics as InMemoryMetricsCollector)
              .getCounter('system.shutdown'),
          1);
    });
  });
}
