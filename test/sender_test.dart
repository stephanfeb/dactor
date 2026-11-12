import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:dactor/spi.dart';
import 'package:test/test.dart';

/// Records what it receives and who sent it.
class Recorder extends Actor {
  final seen = <(Object?, String?)>[];

  @override
  Future<void> onMessage(dynamic message) async =>
      seen.add((message, context.sender?.id));
}

/// Tells [target] whatever it is given, or forwards it with `forward:`.
class Relay extends Actor {
  final ActorRef target;
  Relay(this.target);

  @override
  Future<void> onMessage(dynamic message) async {
    if (message case ('forward', final Object? inner)) {
      context.forward(target, inner);
    } else {
      target.tell(message);
    }
  }
}

class Echo extends Actor {
  @override
  Future<void> onMessage(dynamic message) async =>
      context.sender?.tell('echo $message');
}

class Ticker extends Actor {
  final ActorRef target;
  Ticker(this.target);

  @override
  void preStart() =>
      context.timers.startSingleTimer('t', 'tick', Duration.zero);

  @override
  Future<void> onMessage(dynamic message) async =>
      context.forward(target, message);
}

void main() {
  late LocalActorSystem system;

  setUp(() => system = LocalActorSystem());
  tearDown(() => system.shutdown());

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 20));

  Future<(ActorRef, Recorder)> recorder([String id = 'rec']) async {
    final actor = Recorder();
    return (await system.spawn(id, () => actor), actor);
  }

  test('the sender is the actor whose code tells, and null outside', () async {
    final (ref, rec) = await recorder();
    final relay = await system.spawn('relay', () => Relay(ref));
    ref.tell('outside');
    relay.tell('inside');
    await settle();
    expect(rec.seen, [('outside', null), ('inside', 'relay')]);
  });

  test('forward keeps the original sender, so the answer goes to the asker',
      () async {
    final echo = await system.spawn('echo', () => Echo());
    final relay = await system.spawn('relay', () => Relay(echo));
    expect(await relay.ask<String>(('forward', 'hi')), 'echo hi');
  });

  test('sendAs names the sender for code outside any actor', () async {
    final (ref, rec) = await recorder();
    final (other, _) = await recorder('other');
    sendAs(other, () => ref.tell('x'));
    ref.tell('y');
    await settle();
    expect(rec.seen, [('x', 'other'), ('y', null)]);
  });

  test('a Terminated or ExitSignal told by anyone but the runtime is dropped',
      () async {
    final (ref, rec) = await recorder();
    final (other, _) = await recorder('other');
    ref.tell(Terminated(other));
    ref.tell(ExitSignal(other, const KilledExit()));
    ref.tell('real');
    await settle();
    expect(rec.seen, [('real', null)]);
    expect(system.deadLetterQueue.length, 2);
  });

  test('tellSystem delivers a runtime message', () async {
    final (ref, rec) = await recorder();
    final (other, _) = await recorder('other');
    tellSystem(ref, Terminated(other));
    await settle();
    expect(rec.seen.single.$1, isA<Terminated>());
    expect(rec.seen.single.$2, isNull);
  });

  test('a watcher still hears of an ending', () async {
    final (ref, rec) = await recorder();
    final (other, _) = await recorder('other');
    other.watch(ref);
    await system.stop(other);
    await settle();
    expect(rec.seen.single.$1, isA<Terminated>());
  });

  test('a deprecated LocalMessage is unwrapped and its sender ignored',
      () async {
    final (ref, rec) = await recorder();
    final (other, _) = await recorder('other');
    // ignore: deprecated_member_use
    ref.tell(LocalMessage(payload: 'old', sender: other));
    await settle();
    expect(rec.seen, [('old', null)]);
  });

  test('a timer message has no sender', () async {
    final (ref, rec) = await recorder();
    await system.spawn('ticker', () => Ticker(ref));
    await settle();
    expect(rec.seen, [('tick', null)]);
  });

  test('a reply from an asked actor reaches only the asker', () async {
    final echo = await system.spawn('echo', () => Echo());
    final answers =
        await Future.wait([for (var i = 0; i < 5; i++) echo.ask<String>(i)]);
    expect(answers, [for (var i = 0; i < 5; i++) 'echo $i']);
  });
}
