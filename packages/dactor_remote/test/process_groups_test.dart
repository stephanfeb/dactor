import 'package:dactor/dactor.dart';
import 'package:dactor_remote/dactor_remote.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Process groups on the in-memory network, in real time. The seeded
/// simulation of many histories is in simulated_groups_test.dart.
void main() {
  late InMemoryNetwork network;
  final nodes = <String, TestNode>{};
  final groups = <String, ProcessGroups>{};
  final log = <String>[];

  Future<void> settle([int ms = 50]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  Future<ActorRef> spawn(String on, String name) =>
      nodes[on]!.system.spawn(name, () => Agent(name, log));

  /// The member ids of [group] as node [on] sees them, sorted, with remote
  /// ones reduced to their node and id.
  List<String> seen(String on, String group) => [
        for (final m in groups[on]!.members(group))
          m is RemoteRef ? '${m.node}/${m.path}' : '$on/${m.id}'
      ]..sort();

  setUp(() {
    log.clear();
    network = InMemoryNetwork();
    for (final name in ['a', 'b', 'c']) {
      nodes[name] = join(network, name);
      groups[name] = ProcessGroups(nodes[name]!.remote,
          retry: const Duration(milliseconds: 100));
    }
  });

  tearDown(() async {
    for (final name in nodes.keys) {
      await groups[name]!.close();
      await nodes[name]!.close();
    }
    nodes.clear();
    groups.clear();
  });

  test('members on every node are seen by every node', () async {
    groups['a']!.join('workers', await spawn('a', 'a1'));
    groups['b']!.join('workers', await spawn('b', 'b1'));
    groups['b']!.join('workers', await spawn('b', 'b2'));
    groups['c']!.join('others', await spawn('c', 'c1'));
    // a knows b, b knows c; a and c find each other through b.
    groups['a']!.connect('b');
    groups['b']!.connect('c');
    await settle(100);

    for (final on in ['a', 'b', 'c']) {
      expect(seen(on, 'workers'), ['a/a1', 'b/b1', 'b/b2'], reason: on);
      expect(seen(on, 'others'), ['c/c1'], reason: on);
    }
    expect(groups['a']!.nodes, {'b', 'c'});
    expect(groups['c']!.nodes, {'a', 'b'});
  });

  test('a member found in a group can be sent to', () async {
    groups['b']!.join('echo', await spawn('b', 'bob'));
    groups['a']!.connect('b');
    await settle();
    final bob = groups['a']!.members('echo').single;
    expect(await bob.ask<String>('ping'), 'pong from bob');
  });

  test('leave, and a member that ends, are seen everywhere', () async {
    final a1 = await spawn('a', 'a1');
    final b1 = await spawn('b', 'b1');
    groups['a']!.join('g', a1);
    groups['b']!.join('g', b1);
    groups['b']!.join('h', b1);
    groups['a']!.connect('b');
    groups['a']!.connect('c');
    await settle();
    expect(seen('c', 'g'), ['a/a1', 'b/b1']);

    groups['a']!.leave('g', a1);
    await nodes['b']!.system.stop(b1);
    await settle();
    for (final on in ['a', 'b', 'c']) {
      expect(seen(on, 'g'), isEmpty, reason: on);
      expect(seen(on, 'h'), isEmpty, reason: on);
      expect(groups[on]!.groups, isEmpty, reason: on);
    }
  });

  test('a partition hides the other side, and healing restores it', () async {
    groups['a']!.join('g', await spawn('a', 'a1'));
    groups['b']!.join('g', await spawn('b', 'b1'));
    groups['c']!.join('g', await spawn('c', 'c1'));
    groups['a']!.connect('b');
    groups['a']!.connect('c');
    await settle();
    expect(seen('a', 'g'), ['a/a1', 'b/b1', 'c/c1']);

    network.isolate('a');
    await settle(300);
    expect(seen('a', 'g'), ['a/a1']);
    expect(seen('b', 'g'), ['b/b1', 'c/c1']);

    // Changes on both sides during the partition.
    groups['a']!.join('g', await spawn('a', 'a2'));
    groups['c']!.join('g', await spawn('c', 'c2'));

    network.healAll();
    await settle(400); // the retry timer reconnects
    for (final on in ['a', 'b', 'c']) {
      expect(seen(on, 'g'), ['a/a1', 'a/a2', 'b/b1', 'c/c1', 'c/c2'],
          reason: on);
    }
  });

  test('changes reports joins and leaves, local and remote', () async {
    final events = <String>[];
    groups['a']!.changes.listen(
        (c) => events.add('${c.group} +${c.joined.map((r) => r.id).join(',')} '
            '-${c.left.map((r) => r.id).join(',')}'));
    final a1 = await spawn('a', 'a1');
    groups['a']!.join('g', a1);
    groups['b']!.join('g', await spawn('b', 'b1'));
    groups['a']!.connect('b');
    await settle();
    groups['a']!.leave('g', a1);
    network.partition('a', 'b');
    await settle(300);
    expect(events, [
      'g +a1 -',
      'g +dactor://b/b1 -',
      'g + -a1',
      'g + -dactor://b/b1',
    ]);
  });

  test(
      'a node cannot add another node\'s actors, or local refs that are not '
      'its own', () async {
    final c1 = await spawn('c', 'c1');
    nodes['c']!.remote.expose('c1', c1);
    groups['a']!.connect('b');
    await settle();
    // b gets a reference to c1, then claims it as its own member.
    final c1FromB = await nodes['b']!.remote.lookup('c', 'c1');
    nodes['b']!.remote.sendToService('a', r'$pg/default', [
      'join',
      'g',
    ], refs: [
      c1FromB
    ]);
    await settle();
    expect(groups['a']!.members('g'), isEmpty);

    // Nor can a remote actor be joined locally.
    final c1FromA = await nodes['a']!.remote.lookup('c', 'c1');
    expect(() => groups['a']!.join('g', c1FromA), throwsArgumentError);
  });

  test('accept keeps other nodes out of the scope', () async {
    await groups['c']!.close();
    groups['c'] = ProcessGroups(nodes['c']!.remote,
        accept: (node) => node != 'a',
        retry: const Duration(milliseconds: 100));
    groups['a']!.join('g', await spawn('a', 'a1'));
    groups['b']!.join('g', await spawn('b', 'b1'));
    groups['a']!.connect('c');
    groups['b']!.connect('c');
    await settle(150);
    expect(seen('c', 'g'), ['b/b1']);
  });
  test(
      'a node passed on and gone for good is forgotten; one given to '
      'connect is not', () async {
    for (final name in ['a', 'b']) {
      await groups[name]!.close();
      groups[name] = ProcessGroups(nodes[name]!.remote,
          retry: const Duration(milliseconds: 100),
          forgetAfter: const Duration(milliseconds: 500));
    }
    await groups['c']!.close();
    groups['c'] = ProcessGroups(nodes['c']!.remote,
        retry: const Duration(milliseconds: 100));
    // a learns of c from b.
    groups['a']!.connect('b');
    groups['b']!.connect('c');
    await settle(150);
    expect(groups['a']!.nodes, {'b', 'c'});

    network.isolate('c');
    await settle(900);
    expect(groups['a']!.nodes, {'b'}, reason: 'a was told of c');
    expect(groups['b']!.nodes, {'a', 'c'}, reason: 'b connected to c');

    // b still finds c when it is back, and passes it on again.
    network.healAll();
    await settle(400);
    expect(groups['a']!.nodes, {'b', 'c'});
  });

  test('a node a retry has missed is not passed on', () async {
    groups['a']!.connect('b');
    groups['a']!.connect('c');
    await settle();
    network.isolate('c');
    await settle(450); // noticed, then missed by a retry

    nodes['d'] = join(network, 'd');
    groups['d'] = ProcessGroups(nodes['d']!.remote,
        retry: const Duration(milliseconds: 100));
    groups['d']!.connect('a');
    await settle(150);
    expect(groups['d']!.nodes, {'a', 'b'});
  });
}
