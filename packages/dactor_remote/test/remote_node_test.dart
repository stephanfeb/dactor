import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:dactor_remote/dactor_remote.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late InMemoryNetwork network;
  late TestNode a;
  late TestNode b;
  final log = <String>[];

  setUp(() {
    log.clear();
    network = InMemoryNetwork(detectAfter: const Duration(milliseconds: 30));
    a = join(network, 'a');
    b = join(network, 'b');
  });

  tearDown(() async {
    await a.close();
    await b.close();
  });

  Future<void> settle([int ms = 40]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  /// An agent on [node], exposed under its name.
  Future<ActorRef> agent(TestNode node, String name,
      {bool trap = false, SupervisionStrategy? supervision}) async {
    final ref = await node.system.spawn(
        name, () => Agent(name, log, trap: trap),
        supervision: supervision);
    node.remote.expose(name, ref);
    return ref;
  }

  /// Tells the local agent [to] about a remote one, and returns the remote
  /// reference.
  Future<ActorRef> introduce(
      TestNode from, ActorRef to, TestNode other, String name) async {
    final remote = await from.remote.lookup(other.id, name);
    expect(await to.ask<String>(Introduce(name, remote)), 'met $name');
    return remote;
  }

  group('tell and ask', () {
    test('a looked-up reference takes tell and ask', () async {
      await agent(b, 'bob');
      final bob = await a.remote.lookup('b', 'bob');
      expect(bob, isA<RemoteRef>());
      expect(bob.id, 'dactor://b/bob');
      tell(bob, 'hello');
      expect(await bob.ask<String>('ping'), 'pong from bob');
      expect(log, contains('bob got hello'));
    });

    test('messages arrive in the order sent', () async {
      await b.system.spawn('counter', () => Counter());
      b.remote.expose('counter', b.system.getActor('counter')!);
      final counter =
          (await a.remote.lookup('b', 'counter')).typed<CounterMsg>();
      for (var i = 1; i <= 100; i++) {
        counter.tell(Add(i));
      }
      expect(await counter.call(Get()), 5050);
    });

    test('the sender of a remote tell can be replied to', () async {
      final alice = await agent(a, 'alice');
      await agent(b, 'bob');
      await introduce(a, alice, b, 'bob');
      tell(alice, ('ping', 'bob'));
      await settle();
      expect(log, contains('alice got pong from bob'));
    });

    test('an actor can ask a remote actor from inside a handler', () async {
      final alice = await agent(a, 'alice');
      await agent(b, 'bob');
      await introduce(a, alice, b, 'bob');
      expect(await alice.ask<String>(('ask', 'bob')), 'relayed: pong from bob');
    });

    test('a reference inside a message works where it lands', () async {
      // a hands b a reference to an actor on a; b uses it.
      final alice = await agent(a, 'alice');
      final bob = await agent(b, 'bob');
      final remoteBob = await a.remote.lookup('b', 'bob');
      expect(
          await remoteBob.ask<String>(Introduce('alice', alice)), 'met alice');
      tell(bob, ('ping', 'alice'));
      await settle();
      expect(log, contains('bob got pong from alice'));
    });

    test('a reference that comes home is the local one again', () async {
      final alice = await agent(a, 'alice');
      await agent(b, 'bob');
      final bob = await a.remote.lookup('b', 'bob');
      // b learns of alice, then a third party on a asks b to ping her: the
      // reply path a -> b -> a ends at the local actor.
      await bob.ask<String>(Introduce('alice', alice));
      final carol = await agent(a, 'carol');
      await introduce(a, carol, b, 'bob');
      tell(carol, ('forward', 'bob', ('ping', 'alice')));
      await settle();
      expect(log, contains('bob got pong from alice'));
    });

    test('a forwarded ask is answered to the original asker', () async {
      final alice = await agent(a, 'alice');
      await agent(b, 'bob');
      await introduce(a, alice, b, 'bob');
      // alice forwards the ask to bob; bob's reply goes straight back.
      expect(
          await alice.ask<String>(('forward', 'bob', 'ping')), 'pong from bob');
    });

    test('typed calls work, and a failing handler fails the call', () async {
      await b.system.spawn('counter', () => Counter(7),
          supervision: const OneForOneStrategy(decider: restart));
      b.remote.expose('counter', b.system.getActor('counter')!);
      final counter =
          (await a.remote.lookup('b', 'counter')).typed<CounterMsg>();
      expect(await counter.call(Get()), 7);
      await expectLater(
          counter.call(Fail()),
          throwsA(isA<CallException>()
              .having((e) => '${e.error}', 'error', contains('told to fail'))));
    });

    test('ask fails at once for a dead actor, and times out on silence',
        () async {
      final bob = await agent(b, 'bob');
      final remote = await a.remote.lookup('b', 'bob');
      await b.system.stop(bob);
      await expectLater(remote.ask<String>('ping'), throwsStateError);

      await agent(b, 'quiet');
      final quiet = await a.remote.lookup('b', 'quiet');
      await expectLater(
          quiet.ask<String>(
              'no answer to this', const Duration(milliseconds: 50)),
          throwsA(isA<TimeoutException>()));
    });

    test('a reply of the wrong type fails the ask', () async {
      await agent(b, 'bob');
      final bob = await a.remote.lookup('b', 'bob');
      await expectLater(bob.ask<int>('ping'), throwsStateError);
    });

    test('a message without a codec is refused where it is sent', () async {
      await agent(b, 'bob');
      final bob = await a.remote.lookup('b', 'bob');
      expect(() => tell(bob, DateTime(2026)),
          throwsA(isA<UnregisteredMessageType>()));
      expect(() => bob.ask<String>(Object()),
          throwsA(isA<UnregisteredMessageType>()));
    });

    test('lookup of an unknown name or node fails', () async {
      await expectLater(a.remote.lookup('b', 'nobody'), throwsStateError);
      await expectLater(
          a.remote.lookup('nowhere', 'bob'), throwsA(isA<NodeUnreachable>()));
    });
  });

  group('watch', () {
    test('a remote stop is reported with its reason', () async {
      final alice = await agent(a, 'alice');
      final bob = await agent(b, 'bob');
      await introduce(a, alice, b, 'bob');
      await alice.ask<String>(('watch', 'bob'));
      await settle();
      await b.system.stop(bob);
      await settle();
      expect(log, contains('alice saw dactor://b/bob terminated: normal'));
    });

    test('a remote failure is reported as an error', () async {
      final alice = await agent(a, 'alice');
      final bob = await agent(b, 'bob');
      await introduce(a, alice, b, 'bob');
      await alice.ask<String>(('watch', 'bob'));
      await settle();
      tell(bob, 'boom');
      await settle();
      expect(
          log,
          contains('alice saw dactor://b/bob terminated: '
              'error(RemoteActorError: Bad state: boom in bob)'));
    });

    test('watching an actor that is already gone reports noproc', () async {
      final alice = await agent(a, 'alice');
      final bob = await agent(b, 'bob');
      await introduce(a, alice, b, 'bob');
      await b.system.stop(bob);
      await alice.ask<String>(('watch', 'bob'));
      await settle();
      expect(log, contains('alice saw dactor://b/bob terminated: noproc'));
    });

    test('a lost connection is reported as noconnection', () async {
      final alice = await agent(a, 'alice');
      await agent(b, 'bob');
      await introduce(a, alice, b, 'bob');
      await alice.ask<String>(('watch', 'bob'));
      await settle();
      network.partition('a', 'b');
      await settle(80);
      expect(
          log, contains('alice saw dactor://b/bob terminated: noconnection'));
    });
  });

  group('link', () {
    test('a remote failure brings down a linked actor, which is restarted',
        () async {
      final alice = await agent(a, 'alice',
          supervision: const OneForOneStrategy(decider: restart));
      final bob = await agent(b, 'bob');
      await introduce(a, alice, b, 'bob');
      await alice.ask<String>(('link', 'bob'));
      await settle();
      tell(bob, 'boom');
      await settle();
      expect(log.where((l) => l == 'alice started'), hasLength(2));
      expect(alice.isAlive, isTrue);
    });

    test('the link works in the other direction too', () async {
      // alice links to bob; alice fails; bob, trapping exits, is told.
      final alice = await agent(a, 'alice');
      await agent(b, 'bob', trap: true);
      await introduce(a, alice, b, 'bob');
      await alice.ask<String>(('link', 'bob'));
      await settle();
      tell(alice, 'boom');
      await settle();
      expect(
          log,
          contains('bob got exit from dactor://a/alice: '
              'error(RemoteActorError: Bad state: boom in alice)'));
    });

    test('a normal remote stop does not bring down a linked actor', () async {
      final alice = await agent(a, 'alice');
      final bob = await agent(b, 'bob');
      await introduce(a, alice, b, 'bob');
      await alice.ask<String>(('link', 'bob'));
      await settle();
      await b.system.stop(bob);
      await settle();
      expect(alice.isAlive, isTrue);
    });

    test('a trapping actor gets the signal as a message', () async {
      final alice = await agent(a, 'alice', trap: true);
      final bob = await agent(b, 'bob');
      await introduce(a, alice, b, 'bob');
      await alice.ask<String>(('link', 'bob'));
      await settle();
      b.system.kill(bob);
      await settle();
      expect(log, contains('alice got exit from dactor://b/bob: killed'));
    });

    test('unlink removes it on both sides', () async {
      final alice = await agent(a, 'alice', trap: true);
      final bob = await agent(b, 'bob', trap: true);
      await introduce(a, alice, b, 'bob');
      await alice.ask<String>(('link', 'bob'));
      await settle();
      await alice.ask<String>(('unlink', 'bob'));
      await settle();
      b.system.kill(bob);
      await settle();
      expect(log.where((l) => l.contains('got exit')), isEmpty);
    });

    test('linking to an actor that is gone signals noproc', () async {
      final alice = await agent(a, 'alice', trap: true);
      final bob = await agent(b, 'bob');
      await introduce(a, alice, b, 'bob');
      await b.system.stop(bob);
      await alice.ask<String>(('link', 'bob'));
      await settle();
      expect(log, contains('alice got exit from dactor://b/bob: noproc'));
    });

    test('a lost connection signals both sides with noconnection', () async {
      final alice = await agent(a, 'alice', trap: true);
      await agent(b, 'bob', trap: true);
      await introduce(a, alice, b, 'bob');
      await alice.ask<String>(('link', 'bob'));
      await settle();
      network.partition('a', 'b');
      await settle(80);
      expect(log, contains('alice got exit from dactor://b/bob: noconnection'));
      expect(log, contains('bob got exit from dactor://a/alice: noconnection'));
    });
  });

  group('connections', () {
    test('events report connections made and lost', () async {
      final events = <NodeEvent>[];
      a.remote.events.listen(events.add);
      await agent(b, 'bob');
      await a.remote.lookup('b', 'bob');
      expect(a.remote.isConnected('b'), isTrue);
      network.partition('a', 'b');
      await settle(80);
      expect(a.remote.isConnected('b'), isFalse);
      expect(events.map((e) => '$e'), ['NodeUp(b)', 'NodeDown(b)']);
    });

    test('a pending ask fails when the connection is lost', () async {
      await agent(b, 'quiet');
      final quiet = await a.remote.lookup('b', 'quiet');
      final pending =
          quiet.ask<String>('never answered', const Duration(seconds: 30));
      network.partition('a', 'b');
      await expectLater(pending, throwsA(isA<NodeUnreachable>()));
    });

    test('after the partition heals, the same reference works again', () async {
      await agent(b, 'bob');
      final bob = await a.remote.lookup('b', 'bob');
      network.partition('a', 'b');
      await settle(80);
      await expectLater(
          bob.ask<String>('ping'), throwsA(isA<NodeUnreachable>()));
      network.heal('a', 'b');
      expect(await bob.ask<String>('ping'), 'pong from bob');
    });

    test('closing a node tells the other side', () async {
      final alice = await agent(a, 'alice');
      await agent(b, 'bob');
      await introduce(a, alice, b, 'bob');
      await alice.ask<String>(('watch', 'bob'));
      await settle();
      await b.remote.close();
      await settle();
      expect(
          log, contains('alice saw dactor://b/bob terminated: noconnection'));
    });
  });

  group('remote spawn', () {
    test('starts a registered behaviour with arguments', () async {
      b.remote.registerBehaviour('counter', (args) => Counter(args as int));
      final counter = (await a.remote.spawnOn('b', 'counter', 'c1', args: 40))
          .typed<CounterMsg>();
      counter.tell(Add(2));
      expect(await counter.call(Get()), 42);
      expect(b.system.getActor('c1'), isNotNull);
    });

    test('fails for an unknown behaviour and for a taken id', () async {
      b.remote.registerBehaviour('counter', (args) => Counter());
      await expectLater(
          a.remote.spawnOn('b', 'nothing', 'x'), throwsStateError);
      await a.remote.spawnOn('b', 'counter', 'c1');
      await expectLater(
          a.remote.spawnOn('b', 'counter', 'c1'), throwsStateError);
    });
  });

  group('addresses', () {
    test('a reference survives a trip through text', () async {
      await agent(b, 'bob');
      final bob = await a.remote.lookup('b', 'bob');
      final uri = a.remote.uriOf(bob);
      expect(uri, startsWith('dactor://b/bob?cap='));
      final again = a.remote.resolve(uri);
      expect(again, bob);
      expect(await again.ask<String>('ping'), 'pong from bob');
    });

    test('ids with slashes and odd node names survive too', () async {
      final c = join(network, 'host:4001');
      addTearDown(c.close);
      final ref = await c.system.spawn('sup/kid 1', () => Agent('kid', log));
      final uri = c.remote.uriOf(ref);
      final resolved = a.remote.resolve(uri) as RemoteRef;
      expect(resolved.node, 'host:4001');
      expect(resolved.path, 'sup/kid 1');
      expect(await resolved.ask<String>('ping'), 'pong from kid');
      expect(() => a.remote.resolve('http://b/bob'), throwsFormatException);
      expect(() => a.remote.resolve('dactor://b'), throwsFormatException);
    });
  });
}
