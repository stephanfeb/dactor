import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:dactor_remote/dactor_remote.dart';
import 'package:dactor_remote/tcp.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Where bob lives relative to alice.
enum Placement { sameSystem, inMemoryNetwork, tcp }

/// The same scenarios with alice and bob in one system and on two nodes.
/// What alice observes must be the same, up to how bob is named and how his
/// errors are represented.
void main() {
  for (final placement in Placement.values) {
    group('bob placed ${placement.name}:', () {
      final log = <String>[];
      late TestNode a;
      late TestNode b;
      late ActorRef alice;
      late ActorRef bob; // the real one
      late ActorRef bobFromA; // as alice's side sees him

      /// The log with bob's name and errors reduced to their local form.
      List<String> seen() => [
            for (final line in log)
              line
                  .replaceAll(RegExp(r'dactor://[^/]+/'), '')
                  .replaceAll('RemoteActorError: ', '')
          ];

      Future<void> settle([int ms = 60]) =>
          Future<void>.delayed(Duration(milliseconds: ms));

      Future<void> start(
          {bool aliceTraps = false,
          SupervisionStrategy? aliceSupervision}) async {
        log.clear();
        LocalActorSystem system() => LocalActorSystem(
            ActorSystemConfig(logCollector: const NoOpLogCollector()));
        switch (placement) {
          case Placement.sameSystem:
            final network = InMemoryNetwork();
            a = join(network, 'a');
            b = a;
          case Placement.inMemoryNetwork:
            final network = InMemoryNetwork();
            a = join(network, 'a');
            b = join(network, 'b');
          case Placement.tcp:
            final sa = system(), sb = system();
            a = TestNode(sa,
                RemoteNode(sa, await TcpTransport.bind(), codecs: codecs()));
            b = TestNode(sb,
                RemoteNode(sb, await TcpTransport.bind(), codecs: codecs()));
        }
        addTearDown(() async {
          await a.close();
          if (!identical(a, b)) await b.close();
        });
        alice = await a.system.spawn(
            'alice', () => Agent('alice', log, trap: aliceTraps),
            supervision: aliceSupervision);
        bob = await b.system.spawn('bob', () => Agent('bob', log));
        if (identical(a, b)) {
          bobFromA = bob;
        } else {
          b.remote.expose('bob', bob);
          bobFromA = await a.remote.lookup(b.id, 'bob');
        }
        expect(
            await alice
                .ask<String>(LocalMessage(payload: Introduce('bob', bobFromA))),
            'met bob');
      }

      test('tell, and a reply to the sender', () async {
        await start();
        tell(alice, ('ping', 'bob'));
        await settle();
        expect(seen(), contains('alice got pong from bob'));
      });

      test('ask from outside and from inside a handler', () async {
        await start();
        expect(await bobFromA.ask<String>(LocalMessage(payload: 'ping')),
            'pong from bob');
        expect(await alice.ask<String>(LocalMessage(payload: ('ask', 'bob'))),
            'relayed: pong from bob');
      });

      test('ask to a stopped actor fails with StateError', () async {
        await start();
        await b.system.stop(bob);
        await expectLater(bobFromA.ask<String>(LocalMessage(payload: 'ping')),
            throwsStateError);
      });

      test('watch reports a normal stop', () async {
        await start();
        await alice.ask<String>(LocalMessage(payload: ('watch', 'bob')));
        await settle();
        await b.system.stop(bob);
        await settle();
        expect(seen(), contains('alice saw bob terminated: normal'));
      });

      test('watch reports a failure with its error', () async {
        await start();
        await alice.ask<String>(LocalMessage(payload: ('watch', 'bob')));
        await settle();
        tell(bob, 'boom');
        await settle();
        expect(
            seen(),
            contains(
                'alice saw bob terminated: error(Bad state: boom in bob)'));
      });

      test('watch on a dead actor reports noproc', () async {
        await start();
        await b.system.stop(bob);
        await alice.ask<String>(LocalMessage(payload: ('watch', 'bob')));
        await settle();
        expect(seen(), contains('alice saw bob terminated: noproc'));
      });

      test('a linked failure restarts the supervised partner', () async {
        await start(
            aliceSupervision: const OneForOneStrategy(decider: restart));
        await alice.ask<String>(LocalMessage(payload: ('link', 'bob')));
        await settle();
        tell(bob, 'boom');
        await settle();
        expect(seen().where((l) => l == 'alice started'), hasLength(2));
      });

      test('a trapping partner gets the exit as a message', () async {
        await start(aliceTraps: true);
        await alice.ask<String>(LocalMessage(payload: ('link', 'bob')));
        await settle();
        tell(bob, 'boom');
        await settle();
        expect(seen(),
            contains('alice got exit from bob: error(Bad state: boom in bob)'));
      });

      test('a normal stop leaves a linked partner alone', () async {
        await start();
        await alice.ask<String>(LocalMessage(payload: ('link', 'bob')));
        await settle();
        await b.system.stop(bob);
        await settle();
        expect(alice.isAlive, isTrue);
        expect(seen().where((l) => l.contains('exit')), isEmpty);
      });

      test('linking to a dead actor signals noproc', () async {
        await start(aliceTraps: true);
        await b.system.stop(bob);
        await alice.ask<String>(LocalMessage(payload: ('link', 'bob')));
        await settle();
        expect(seen(), contains('alice got exit from bob: noproc'));
      });

      test('unlink ends the link', () async {
        await start(aliceTraps: true);
        await alice.ask<String>(LocalMessage(payload: ('link', 'bob')));
        await settle();
        await alice.ask<String>(LocalMessage(payload: ('unlink', 'bob')));
        await settle();
        tell(bob, 'boom');
        await settle();
        expect(seen().where((l) => l.contains('exit')), isEmpty);
      });
    });
  }

  group('over tcp only:', () {
    test('a node that goes away is noticed, and a new one is reachable',
        () async {
      final log = <String>[];
      LocalActorSystem system() => LocalActorSystem(
          ActorSystemConfig(logCollector: const NoOpLogCollector()));
      final sa = system(), sb = system();
      final a = TestNode(
          sa, RemoteNode(sa, await TcpTransport.bind(), codecs: codecs()));
      final b = TestNode(
          sb, RemoteNode(sb, await TcpTransport.bind(), codecs: codecs()));
      addTearDown(a.close);

      final alice = await sa.spawn('alice', () => Agent('alice', log));
      b.remote.expose('bob', await sb.spawn('bob', () => Agent('bob', log)));
      final bob = await a.remote.lookup(b.id, 'bob');
      await alice.ask<String>(LocalMessage(payload: Introduce('bob', bob)));
      await alice.ask<String>(LocalMessage(payload: ('watch', 'bob')));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await b.close();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(log, contains('alice saw ${bob.id} terminated: noconnection'));
      await expectLater(bob.ask<String>(LocalMessage(payload: 'ping')),
          throwsA(isA<NodeUnreachable>()));

      // A fresh node somewhere else is reachable as usual.
      final sc = system();
      final c = TestNode(
          sc, RemoteNode(sc, await TcpTransport.bind(), codecs: codecs()));
      addTearDown(c.close);
      c.remote.expose('carl', await sc.spawn('carl', () => Agent('carl', log)));
      final carl = await a.remote.lookup(c.id, 'carl');
      expect(await carl.ask<String>(LocalMessage(payload: 'ping')),
          'pong from carl');
    });

    test('large and many frames arrive whole and in order', () async {
      LocalActorSystem system() => LocalActorSystem(
          ActorSystemConfig(logCollector: const NoOpLogCollector()));
      final sa = system(), sb = system();
      final a = TestNode(
          sa, RemoteNode(sa, await TcpTransport.bind(), codecs: codecs()));
      final b = TestNode(
          sb, RemoteNode(sb, await TcpTransport.bind(), codecs: codecs()));
      addTearDown(a.close);
      addTearDown(b.close);
      b.remote.expose('counter', await sb.spawn('counter', () => Counter()));
      final counter =
          (await a.remote.lookup(b.id, 'counter')).typed<CounterMsg>();
      for (var i = 1; i <= 5000; i++) {
        counter.tell(Add(i));
      }
      expect(await counter.call(Get()), 12502500);

      final log = <String>[];
      b.remote.expose('bob', await sb.spawn('bob', () => Agent('bob', log)));
      final bob = await a.remote.lookup(b.id, 'bob');
      final big = 'x' * (2 * 1024 * 1024);
      tell(bob, big);
      expect(await bob.ask<String>(LocalMessage(payload: 'ping')),
          'pong from bob');
      expect(log.last.length, greaterThan(2 * 1024 * 1024));
    });
  });
}
