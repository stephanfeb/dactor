import 'dart:async';
import 'dart:io';

import 'package:dactor/dactor.dart';
import 'package:test/test.dart';

final _log = <String>[];

sealed class Animal {}

class Dog extends Animal {
  @override
  String toString() => 'Dog';
}

class Cat extends Animal {
  @override
  String toString() => 'Cat';
}

/// Subscribes to what it is told and logs what arrives.
class Listener extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {
    switch (message) {
      case 'animals':
        context.subscribe<Animal>();
      case 'dogs':
        context.subscribe<Dog>();
      case 'everything':
        context.subscribe<Object>();
      case ('watch', ActorRef target):
        context.watch(target);
      case Terminated(:final actor):
        _log.add('${context.self.id} saw ${actor.id} end');
      default:
        _log.add('${context.self.id} got $message');
    }
  }
}

class Idle extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {}
}

void main() {
  late LocalActorSystem system;

  setUp(() {
    _log.clear();
    system = LocalActorSystem(
        ActorSystemConfig(logCollector: const NoOpLogCollector()));
  });

  tearDown(() => system.shutdown());

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 20));

  group('event bus', () {
    test('a subscriber to a type gets its subtypes', () async {
      final a = await system.spawn('a', () => Listener());
      a.tell('animals');
      await settle();
      system.eventBus.publish(Dog());
      system.eventBus.publish(Cat());
      system.eventBus.publish('not an animal');
      await settle();
      expect(_log, ['a got Dog', 'a got Cat']);
    });

    test('matching is on the event, not the type argument', () async {
      final d = await system.spawn('d', () => Listener());
      d.tell('dogs');
      await settle();
      system.eventBus.publish<Animal>(Dog());
      system.eventBus.publish<Animal>(Cat());
      await settle();
      expect(_log, ['d got Dog']);
    });

    test('several matching subscriptions deliver once', () async {
      final a = await system.spawn('a', () => Listener());
      a
        ..tell('animals')
        ..tell('dogs')
        ..tell('everything');
      await settle();
      system.eventBus.publish(Dog());
      await settle();
      expect(_log, ['a got Dog']);
    });

    test('publish after dispose is dropped', () {
      final bus = EventBus()..dispose();
      expect(() => bus.publish(Dog()), returnsNormally);
    });
  });

  test('watching twice still means one Terminated', () async {
    final w = await system.spawn('w', () => Listener());
    final target = await system.spawn('target', () => Idle());
    w
      ..tell(('watch', target))
      ..tell(('watch', target));
    await settle();
    await system.stop(target);
    await settle();
    expect(_log, ['w saw target end']);
  });

  test('dead letters can be followed as they arrive', () async {
    final seen = <Object?>[];
    final sub =
        system.deadLetterQueue.letters.listen((l) => seen.add(l.message));
    final gone = await system.spawn('gone', () => Idle());
    await system.stop(gone);
    gone.tell('late');
    await settle();
    expect(seen, ['late']);
    // Following them does not take them out of the queue.
    expect(system.deadLetterQueue.toList().map((l) => l.message), ['late']);
    await sub.cancel();
  });

  group('InMemoryMetricsCollector', () {
    test('keeps tagged series beside the totals', () {
      final metrics = InMemoryMetricsCollector()
        ..increment('hits', tags: {'actorId': 'a'})
        ..increment('hits', tags: {'actorId': 'b'}, count: 2)
        ..decrement('hits', tags: {'actorId': 'b'})
        ..gauge('size', 3, tags: {'actorId': 'a'})
        ..gauge('size', 7, tags: {'actorId': 'b'});
      expect(metrics.getCounter('hits'), 2);
      expect(metrics.getCounter('hits', tags: {'actorId': 'a'}), 1);
      expect(metrics.getCounter('hits', tags: {'actorId': 'b'}), 1);
      expect(metrics.getGauge('size', tags: {'actorId': 'a'}), 3);
      expect(metrics.getGauge('size'), 7);
    });

    test('tag order does not matter', () {
      final metrics = InMemoryMetricsCollector()
        ..increment('x', tags: {'a': '1', 'b': '2'});
      expect(metrics.getCounter('x', tags: {'b': '2', 'a': '1'}), 1);
    });
  });

  group('AskConfig', () {
    test('error types match exactly', () {
      final config = AskConfig(retryableErrorTypes: {Exception});
      expect(config.isRetryableError(const FileSystemException()), isFalse);
      expect(config.isRetryableError(TimeoutException('t')), isFalse);
    });

    test('retryIf matches subtypes', () {
      final config = AskConfig(retryIf: (e) => e is IOException);
      expect(config.isRetryableError(const FileSystemException()), isTrue);
      expect(config.isRetryableError(TimeoutException('t')), isFalse);
    });
  });
}
