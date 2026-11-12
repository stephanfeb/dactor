import 'package:dactor/dactor.dart';
import 'package:dactor/simulation.dart';
import 'package:dactor_remote/dactor_remote.dart';
import 'package:test/test.dart';

import 'support.dart';

const _nodeNames = ['a', 'b', 'c', 'd'];
const _groupNames = ['g0', 'g1', 'g2'];

/// Four nodes on a simulated network under the seeded scheduler. Random
/// joins, leaves, actor deaths, partitions and heals, then the network
/// heals for good. Returns a summary of the history.
///
/// What must hold at the end: every node sees, for every group, exactly
/// the members that the nodes hold locally, and every member is alive.
Future<String> groupsHistory(Simulation sim) async {
  final network = InMemoryNetwork(
      latency: const Duration(milliseconds: 5),
      jitter: const Duration(milliseconds: 20),
      detectAfter: const Duration(milliseconds: 300),
      random: sim.random);
  final nodes = <String, TestNode>{};
  final groups = <String, ProcessGroups>{};
  final actors = <String, List<ActorRef>>{};
  final events = <String>[];
  for (final (i, name) in _nodeNames.indexed) {
    nodes[name] =
        join(network, name, system: i == 0 ? sim.system : sim.addSystem());
    groups[name] = ProcessGroups(nodes[name]!.remote,
        retry: const Duration(milliseconds: 200));
    actors[name] = [];
  }
  // A chain; the mesh comes from the nodes passing on who they know.
  groups['a']!.connect('b');
  groups['b']!.connect('c');
  groups['c']!.connect('d');

  try {
    var spawned = 0;
    Future<void> spawnOn(String node) async {
      final name = 'x${spawned++}';
      actors[node]!
          .add(await nodes[node]!.system.spawn(name, () => Agent(name, [])));
    }

    for (final node in _nodeNames) {
      for (var i = 0; i < 2; i++) {
        await spawnOn(node);
      }
    }

    T pick<T>(List<T> items) => items[sim.random.nextInt(items.length)];

    for (var step = 0; step < 40; step++) {
      final node = pick(_nodeNames);
      final live = actors[node]!.where((a) => a.isAlive).toList();
      switch (sim.random.nextInt(10)) {
        case 0 || 1 || 2 || 3 when live.isNotEmpty:
          final (actor, group) = (pick(live), pick(_groupNames));
          groups[node]!.join(group, actor);
          events.add('$node join $group ${actor.id}');
        case 4 || 5 when live.isNotEmpty:
          final (actor, group) = (pick(live), pick(_groupNames));
          groups[node]!.leave(group, actor);
          events.add('$node leave $group ${actor.id}');
        case 6 when live.isNotEmpty:
          final actor = pick(live);
          await nodes[node]!.system.stop(actor);
          await spawnOn(node);
          events.add('$node stop ${actor.id}');
        case 7 || 8:
          final other = pick(_nodeNames.where((n) => n != node).toList());
          network.partition(node, other);
          events.add('cut $node-$other');
        case _:
          final other = pick(_nodeNames.where((n) => n != node).toList());
          network.heal(node, other);
          events.add('heal $node-$other');
      }
      await sim.wait(Duration(milliseconds: sim.random.nextInt(60)));
    }

    network.healAll();
    // Enough for lost connections to be noticed (300 ms), retried (200 ms)
    // and synced, a few times over.
    await sim.wait(const Duration(seconds: 3));

    String describe(String on, ActorRef ref) =>
        ref is RemoteRef ? '${ref.node}/${ref.path}' : '$on/${ref.id}';
    final truth = {
      for (final group in _groupNames)
        group: {
          for (final on in _nodeNames)
            for (final m in groups[on]!.localMembers(group)) describe(on, m)
        }
    };
    for (final on in _nodeNames) {
      for (final m in [
        for (final g in _groupNames) ...groups[on]!.localMembers(g)
      ]) {
        expect(m.isAlive, isTrue, reason: 'dead member ${m.id} on $on');
      }
      expect(groups[on]!.nodes, _nodeNames.where((n) => n != on).toSet(),
          reason: 'mesh at $on');
      for (final group in _groupNames) {
        expect({for (final m in groups[on]!.members(group)) describe(on, m)},
            truth[group],
            reason: '$group as seen from $on after: ${events.join('; ')}');
      }
    }
    return [...events, for (final g in _groupNames) '$g ${truth[g]}']
        .join('\n');
  } finally {
    for (final on in _nodeNames) {
      await groups[on]!.close();
      await nodes[on]!.remote.close();
    }
  }
}

/// Like [groupsHistory], for global names: random registrations, deaths,
/// partitions and heals. At the end, every name has one holder, it is
/// alive, and every node agrees on it.
Future<String> namesHistory(Simulation sim) async {
  final network = InMemoryNetwork(
      latency: const Duration(milliseconds: 5),
      jitter: const Duration(milliseconds: 20),
      detectAfter: const Duration(milliseconds: 300),
      random: sim.random);
  final nodes = <String, TestNode>{};
  final names = <String, GlobalNames>{};
  final log = <String>[];
  final events = <String>[];
  for (final (i, name) in _nodeNames.indexed) {
    nodes[name] =
        join(network, name, system: i == 0 ? sim.system : sim.addSystem());
    names[name] = GlobalNames(nodes[name]!.remote,
        retry: const Duration(milliseconds: 200));
  }
  for (final other in _nodeNames.skip(1)) {
    names['a']!.connect(other);
  }
  await sim.wait(const Duration(milliseconds: 200));

  try {
    T pick<T>(List<T> items) => items[sim.random.nextInt(items.length)];
    final holders = <ActorRef>[];
    var spawned = 0;

    for (var step = 0; step < 30; step++) {
      final node = pick(_nodeNames);
      switch (sim.random.nextInt(8)) {
        case 0 || 1 || 2:
          final id = 'y${spawned++}';
          final actor =
              await nodes[node]!.system.spawn(id, () => Agent(id, log));
          final name = pick(const ['leader', 'db', 'cache']);
          final ok = names[node]!.register(name, actor);
          if (ok) holders.add(actor);
          events.add('$node register $name $id: $ok');
        case 3:
          final live = holders
              .where((h) =>
                  h.isAlive && identical(nodes[node]!.system.getActor(h.id), h))
              .toList();
          if (live.isNotEmpty) {
            final actor = pick(live);
            await nodes[node]!.system.stop(actor);
            events.add('$node stop ${actor.id}');
          }
        case 4 || 5:
          final other = pick(_nodeNames.where((n) => n != node).toList());
          network.partition(node, other);
          events.add('cut $node-$other');
        case _:
          final other = pick(_nodeNames.where((n) => n != node).toList());
          network.heal(node, other);
          events.add('heal $node-$other');
      }
      await sim.wait(Duration(milliseconds: sim.random.nextInt(60)));
    }

    network.healAll();
    await sim.wait(const Duration(seconds: 3));

    final view = <String>[];
    for (final name in const ['leader', 'db', 'cache']) {
      // How many nodes hold the name locally: at most one, after all that.
      final holding = [
        for (final on in _nodeNames)
          if (names[on]!.whereis(name) case final ref? when ref is! RemoteRef)
            on
      ];
      expect(holding.length, lessThanOrEqualTo(1),
          reason: '$name held on $holding after: ${events.join('; ')}');
      final seen = {
        for (final on in _nodeNames)
          switch (names[on]!.whereis(name)) {
            null => 'none',
            RemoteRef ref => '${ref.node}/${ref.path}',
            final ref => '$on/${ref.id}',
          }
      };
      expect(seen, hasLength(1),
          reason: '$name seen as $seen after: ${events.join('; ')}');
      if (holding.isNotEmpty) {
        expect(names[holding.single]!.whereis(name)!.isAlive, isTrue);
      }
      view.add('$name ${seen.single}');
    }
    return [
      ...events,
      ...view,
      ...log.where((l) => l.contains('NameConflict')),
    ].join('\n');
  } finally {
    for (final on in _nodeNames) {
      await names[on]!.close();
      await nodes[on]!.remote.close();
    }
  }
}

void main() {
  test('groups agree with the truth after any history (300 seeds)', () {
    final outcomes = <String>{};
    explore((sim) async => outcomes.add(await groupsHistory(sim)), seeds: 300);
    expect(outcomes.length, greaterThan(250));
  });

  test('a groups history replays from its seed', () {
    final first = simulate(groupsHistory, seed: 11);
    expect(simulate(groupsHistory, seed: 11), first);
    expect(simulate(groupsHistory, seed: 12), isNot(first));
  });

  test('every name has one holder that all nodes agree on (300 seeds)', () {
    final outcomes = <String>{};
    var conflicts = 0;
    explore((sim) async {
      final outcome = await namesHistory(sim);
      if (outcome.contains('NameConflict')) conflicts++;
      outcomes.add(outcome);
    }, seeds: 300);
    expect(outcomes.length, greaterThan(250));
    // Some histories did have to resolve a conflict.
    expect(conflicts, greaterThan(10));
  });
}
