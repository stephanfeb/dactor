import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:test/test.dart';

/// Watches and unwatches what it is told to, and records every Terminated.
class Watcher extends Actor {
  final List<String> seen;
  Watcher(this.seen);

  @override
  Future<void> onMessage(dynamic message) async {
    switch (message) {
      case ('watch', ActorRef target):
        context.watch(target);
      case ('unwatch', ActorRef target):
        context.unwatch(target);
      // Waits until [release] completes, then unwatches: whatever arrived
      // meanwhile is still queued when the unwatch happens.
      case ('unwatch after', ActorRef target, Future<void> release):
        await release;
        context.unwatch(target);
      case Terminated(:final actor, :final reason):
        seen.add('${actor.id} $reason');
    }
    context.sender?.tell('done');
  }
}

/// A watcher that is not an actor and unwatches as soon as it is told,
/// as a service watching on behalf of others may.
class UnwatchingRef implements ActorRef {
  final List<String> seen;
  UnwatchingRef(this.seen);

  @override
  String get id => 'unwatching';
  @override
  bool get isAlive => true;
  @override
  void tell(Object? message) {
    final payload = message;
    if (payload is Terminated) {
      seen.add(payload.actor.id);
      payload.actor.unwatch(this);
    }
  }

  @override
  Future<T> ask<T>(Object? message, [Duration? timeout]) =>
      throw UnsupportedError('not an actor');
  @override
  void watch(ActorRef watcher) {}
  @override
  void unwatch(ActorRef watcher) {}
}

class Idle extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {}
}

void main() {
  late LocalActorSystem system;
  setUp(() => system = LocalActorSystem(
      ActorSystemConfig(logCollector: const NoOpLogCollector())));
  tearDown(() => system.shutdown());

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 20));

  test('after unwatch, a stop is not reported', () async {
    final seen = <String>[];
    final watcher = await system.spawn('watcher', () => Watcher(seen));
    final target = await system.spawn('target', () => Idle());
    await watcher.ask(('watch', target));
    await watcher.ask(('unwatch', target));
    await system.stop(target);
    await settle();
    expect(seen, isEmpty);
  });

  test('unwatch removes only that watcher', () async {
    final seenA = <String>[], seenB = <String>[];
    final a = await system.spawn('a', () => Watcher(seenA));
    final b = await system.spawn('b', () => Watcher(seenB));
    final target = await system.spawn('target', () => Idle());
    await a.ask(('watch', target));
    await b.ask(('watch', target));
    await a.ask(('unwatch', target));
    await system.stop(target);
    await settle();
    expect(seenA, isEmpty);
    expect(seenB, hasLength(1));
  });

  test('context.unwatch drops a Terminated already queued', () async {
    final seen = <String>[];
    final watcher = await system.spawn('watcher', () => Watcher(seen));
    final target = await system.spawn('target', () => Idle());
    await watcher.ask(('watch', target));

    final release = Completer<void>();
    final unwatched = watcher.ask(('unwatch after', target, release.future));
    // The watcher is busy; the Terminated waits in its mailbox.
    await system.stop(target);
    await settle();
    release.complete();
    await unwatched;
    await settle();
    expect(seen, isEmpty);
  });

  test('a plain ActorRef.unwatch leaves an already queued Terminated',
      () async {
    final seen = <String>[];
    final watcher = await system.spawn('watcher', () => Watcher(seen));
    final target = await system.spawn('target', () => Idle());
    await watcher.ask(('watch', target));
    final release = Completer<void>();
    final busy = watcher.ask((
      'unwatch after',
      await system.spawn('other', () => Idle()),
      release.future
    ));
    await system.stop(target);
    await settle();
    target.unwatch(watcher); // too late: it is already queued
    release.complete();
    await busy;
    await settle();
    expect(seen, hasLength(1));
  });

  test('context.unwatch drops the noproc of an actor already dead', () async {
    final seen = <String>[];
    final watcher = await system.spawn('watcher', () => Watcher(seen));
    final target = await system.spawn('target', () => Idle());
    await system.stop(target);
    final release = Completer<void>();
    // Watch (noproc is queued at once), then unwatch before it is handled.
    final busy = watcher.ask(('unwatch after', target, release.future));
    target.watch(watcher);
    release.complete();
    await busy;
    await settle();
    expect(seen, isEmpty);
  });

  test('a watcher may unwatch while it is told of the end', () async {
    final seen = <String>[];
    final target = await system.spawn('target', () => Idle());
    final first = UnwatchingRef(seen), second = UnwatchingRef(seen);
    target.watch(first);
    target.watch(second);
    await system.stop(target);
    expect(seen, ['target', 'target']);
  });
}
