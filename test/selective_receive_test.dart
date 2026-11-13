import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:dactor/spi.dart';
import 'package:test/test.dart';

final _log = <String>[];

class Ack {
  final int id;
  Ack(this.id);
}

/// On 'start', waits for the Ack with the id it was built with.
class Waiter extends Actor {
  final int want;
  final Duration? timeout;
  Waiter(this.want, {this.timeout});

  @override
  Future<void> onMessage(dynamic message) async {
    switch (message) {
      case 'start':
        try {
          final ack = await context.receive<Ack>(
              where: (a) => a.id == want, timeout: timeout);
          _log.add('got ack ${ack.id}');
        } on TimeoutException {
          _log.add('timed out');
        }
      case 'twice':
        unawaited(context.receive<Ack>().then((_) {}, onError: (_) {}));
        try {
          await context.receive<Ack>();
        } on StateError {
          _log.add('second receive refused');
        }
      case Ack(:final id):
        _log.add('ack $id as ordinary message');
      default:
        _log.add('$message');
    }
  }
}

/// Waits for an Ack, thanks whoever sent it, and then answers whoever asked.
class Collector extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {
    if (message != 'collect') return;
    final asker = context.sender;
    final ack = await context.receive<Ack>();
    context.sender?.tell('thanks ${ack.id}');
    asker?.tell('collected ${ack.id}');
  }
}

/// Logs what it is told.
class Recorder extends Actor {
  @override
  Future<void> onMessage(dynamic message) async => _log.add('$message');
}

void main() {
  late LocalActorSystem system;

  setUp(() {
    _log.clear();
    system = LocalActorSystem();
  });

  tearDown(() => system.shutdown());

  Future<void> settle([int ms = 15]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  void send(ActorRef ref, Object message) => ref.tell(message);

  test('takes a matching message that arrives later, out of order', () async {
    final ref = await system.spawn('w', () => Waiter(2));
    send(ref, 'start');
    await settle();
    send(ref, 'a');
    send(ref, Ack(1));
    send(ref, Ack(2));
    send(ref, 'b');
    await settle();
    expect(_log, ['got ack 2', 'a', 'ack 1 as ordinary message', 'b']);
  });

  test('takes a matching message already in the mailbox', () async {
    final ref = await system.spawn('w', () => Waiter(7));
    system.sys.suspend(ref);
    send(ref, 'start');
    send(ref, 'a');
    send(ref, Ack(7));
    system.sys.resume(ref);
    await settle();
    expect(_log, ['got ack 7', 'a']);
  });

  test('times out, and the actor carries on', () async {
    final ref = await system.spawn(
        'w', () => Waiter(1, timeout: const Duration(milliseconds: 20)));
    send(ref, 'start');
    send(ref, Ack(9));
    await settle(60);
    send(ref, Ack(1));
    await settle();
    expect(_log, [
      'timed out',
      'ack 9 as ordinary message',
      'ack 1 as ordinary message'
    ]);
  });

  test('one receive at a time', () async {
    final ref = await system.spawn('w', () => Waiter(1));
    send(ref, 'twice');
    await settle();
    expect(_log, ['second receive refused']);
    // The abandoned receive ended with its handler.
    send(ref, Ack(5));
    await settle();
    expect(_log.last, 'ack 5 as ordinary message');
  });

  test('is refused outside a handler', () async {
    final (:ref, :actor) = await system.spawnAndGetActor('w', () => Waiter(1));
    expect(ref.isAlive, isTrue);
    expect(() => actor.context.receive<Ack>(), throwsStateError);
  });

  test('a waiting actor can be stopped and killed', () async {
    await system.shutdown();
    system = LocalActorSystem(
        ActorSystemConfig(stopTimeout: const Duration(milliseconds: 20)));
    final ref = await system.spawn('w', () => Waiter(1));
    send(ref, 'start');
    await settle();
    await system.stop(ref);
    expect(ref.isAlive, isFalse);
    expect(_log, isEmpty);
  });

  test('sender is the sender of the received message', () async {
    final collector = await system.spawn('c', () => Collector());
    final acker = await system.spawn('acker', () => Recorder());
    final collected = collector.ask<String>('collect');
    await settle();
    sendAs(acker, () => collector.tell(Ack(3)));
    expect(await collected, 'collected 3');
    await settle();
    expect(_log, ['thanks 3']);
  });
}
