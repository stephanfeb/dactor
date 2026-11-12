import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:dactor/simulation.dart';
import 'package:dactor_remote/dactor_remote.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Two nodes on a simulated network, under the seeded scheduler: message
/// order, timer order, network jitter and the moment of the partition all
/// come from the seed.
Future<List<String>> partitionAndRecover(Simulation sim) async {
  final log = <String>[];
  final network = InMemoryNetwork(
      latency: const Duration(milliseconds: 5),
      jitter: const Duration(milliseconds: 20),
      detectAfter: const Duration(milliseconds: 300),
      random: sim.random);
  final a = join(network, 'a', system: sim.system);
  final b = join(network, 'b', system: sim.addSystem());

  final alice =
      await a.system.spawn('alice', () => Agent('alice', log, trap: true));
  final bob = await b.system.spawn('bob', () => Agent('bob', log, trap: true));
  final sink = await b.system.spawn('sink', () => Agent('sink', log));
  b.remote
    ..expose('bob', bob)
    ..expose('sink', sink);

  final remoteBob = await a.remote.lookup('b', 'bob');
  final remoteSink = await a.remote.lookup('b', 'sink');
  await alice.ask<String>(Introduce('bob', remoteBob));
  await alice.ask<String>(('watch', 'bob'));
  await alice.ask<String>(('link', 'bob'));
  await sim.wait(const Duration(milliseconds: 100));

  // A stream of numbered messages, with the partition at a random point.
  final cutAt = sim.random.nextInt(40);
  Future<String>? caught;
  for (var i = 0; i < 40; i++) {
    if (i == cutAt) {
      // An ask in flight when the path is cut.
      caught = remoteBob
          .ask<String>('ping', const Duration(hours: 1))
          .then((v) => 'answered', onError: (Object e) => '${e.runtimeType}');
      network.partition('a', 'b');
    }
    tell(remoteSink, i);
    await sim.wait(Duration(milliseconds: sim.random.nextInt(10)));
  }
  await sim.wait(const Duration(seconds: 1));

  // Both sides were told, each about the other.
  expect(log, contains('alice saw dactor://b/bob terminated: noconnection'));
  expect(log, contains('alice got exit from dactor://b/bob: noconnection'));
  expect(log, contains('bob got exit from dactor://a/alice: noconnection'));
  // Nobody was brought down by it.
  expect(alice.isAlive && bob.isAlive, isTrue);
  // The ask either got through before the cut took effect or failed with
  // the connection; it did not hang until its timeout.
  expect(await caught, anyOf('answered', 'NodeUnreachable'));
  expect(a.remote.isConnected('b'), isFalse);

  // What reached the sink is in order, with nothing after the cut.
  final received = [
    for (final line in log)
      if (line.startsWith('sink got ')) int.parse(line.substring(9))
  ];
  expect(received, orderedEquals([...received]..sort()));
  expect(received.toSet(), hasLength(received.length));
  expect(received.every((n) => n < cutAt), isTrue);

  // Recovery: the same references work again, and so do new watches.
  network.heal('a', 'b');
  expect(await remoteBob.ask<String>('ping'), 'pong from bob');
  expect(a.remote.isConnected('b'), isTrue);
  tell(remoteSink, 1000);
  await alice.ask<String>(('watch', 'bob'));
  await sim.wait(const Duration(milliseconds: 100));
  await b.system.stop(bob);
  await sim.wait(const Duration(milliseconds: 100));
  expect(log, contains('sink got 1000'));
  expect(log.last, 'alice saw dactor://b/bob terminated: normal');

  await a.remote.close();
  await b.remote.close();
  return [...log, 'cut at $cutAt', 'received ${received.length}'];
}

void main() {
  test('a partition delivers noconnection and the nodes recover (500 seeds)',
      () {
    final outcomes = <String>{};
    explore((sim) async {
      outcomes.add((await partitionAndRecover(sim)).join('\n'));
    }, seeds: 500);
    // The seeds really did produce different histories.
    expect(outcomes.length, greaterThan(100));
  });

  test('a seed replays to the same history, network and all', () {
    for (final seed in [3, 77]) {
      final first = simulate(partitionAndRecover, seed: seed);
      for (var i = 0; i < 5; i++) {
        expect(simulate(partitionAndRecover, seed: seed), first);
      }
    }
    expect(simulate(partitionAndRecover, seed: 3),
        isNot(simulate(partitionAndRecover, seed: 77)));
  });

  test('a node that is cut off for good is noticed by everyone', () {
    explore((sim) async {
      final log = <String>[];
      final network = InMemoryNetwork(random: sim.random);
      final nodes = [
        join(network, 'n0', system: sim.system),
        join(network, 'n1', system: sim.addSystem()),
        join(network, 'n2', system: sim.addSystem()),
      ];
      final agents = <ActorRef>[];
      for (final (i, node) in nodes.indexed) {
        final ref = await node.system
            .spawn('agent', () => Agent('agent$i', log, trap: true));
        node.remote.expose('agent', ref);
        agents.add(ref);
      }
      // Everyone watches everyone else.
      for (final (i, node) in nodes.indexed) {
        for (final (j, other) in nodes.indexed) {
          if (i == j) continue;
          final remote = await node.remote.lookup(other.id, 'agent');
          await agents[i].ask<String>(Introduce('n$j', remote));
          await agents[i].ask<String>(('watch', 'n$j'));
        }
      }
      await sim.wait(const Duration(milliseconds: 50));
      network.isolate('n2');
      await sim.wait(const Duration(seconds: 1));

      final lost = log.where((l) => l.contains('noconnection')).toSet();
      expect(lost, {
        'agent0 saw dactor://n2/agent terminated: noconnection',
        'agent1 saw dactor://n2/agent terminated: noconnection',
        'agent2 saw dactor://n0/agent terminated: noconnection',
        'agent2 saw dactor://n1/agent terminated: noconnection',
      });
      // The two that can still talk, still do.
      final n1 = await nodes[0].remote.lookup('n1', 'agent');
      expect(await n1.ask<String>('ping'), 'pong from agent1');
      for (final node in nodes) {
        await node.remote.close();
      }
    }, seeds: 100);
  });
}
