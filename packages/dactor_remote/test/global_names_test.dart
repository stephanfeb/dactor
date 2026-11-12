import 'package:dactor/dactor.dart';
import 'package:dactor_remote/dactor_remote.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late InMemoryNetwork network;
  final nodes = <String, TestNode>{};
  final names = <String, GlobalNames>{};
  final log = <String>[];

  Future<void> settle([int ms = 50]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  Future<ActorRef> spawn(String on, String name) =>
      nodes[on]!.system.spawn(name, () => Agent(name, log));

  String? holder(String on, String name) => switch (names[on]!.whereis(name)) {
        null => null,
        RemoteRef ref => '${ref.node}/${ref.path}',
        final ref => '$on/${ref.id}',
      };

  setUp(() async {
    log.clear();
    network = InMemoryNetwork();
    for (final name in ['a', 'b', 'c']) {
      nodes[name] = join(network, name);
      names[name] = GlobalNames(nodes[name]!.remote,
          retry: const Duration(milliseconds: 100));
    }
    names['a']!.connect('b');
    names['a']!.connect('c');
    await settle();
  });

  tearDown(() async {
    for (final name in nodes.keys) {
      await names[name]!.close();
      await nodes[name]!.close();
    }
    nodes.clear();
    names.clear();
  });

  test('a registered name is found from every node', () async {
    expect(names['b']!.register('db', await spawn('b', 'store')), isTrue);
    await settle();
    for (final on in ['a', 'b', 'c']) {
      expect(holder(on, 'db'), 'b/store', reason: on);
    }
    final db = names['c']!.whereis('db')!;
    expect(
        await db.ask<String>(LocalMessage(payload: 'ping')), 'pong from store');
  });

  test('a name held elsewhere is refused', () async {
    expect(names['b']!.register('db', await spawn('b', 'store')), isTrue);
    await settle();
    expect(names['c']!.register('db', await spawn('c', 'other')), isFalse);
    expect(names['b']!.register('db', await spawn('b', 'again')), isFalse);
  });

  test('a name is released when its actor ends, or is unregistered', () async {
    final store = await spawn('b', 'store');
    names['b']!.register('db', store);
    names['b']!.register('cache', store);
    await settle();
    await nodes['b']!.system.stop(store);
    await settle();
    for (final on in ['a', 'b', 'c']) {
      expect(names[on]!.whereis('db'), isNull, reason: on);
      expect(names[on]!.names, isEmpty, reason: on);
    }
    expect(names['c']!.register('db', await spawn('c', 'next')), isTrue);
    await settle();
    names['c']!.unregister('db');
    await settle();
    expect(names['a']!.whereis('db'), isNull);
  });

  test('a name taken on both sides of a partition has one holder after it',
      () async {
    network.isolate('c');
    await settle(300);
    expect(names['a']!.register('leader', await spawn('a', 'la')), isTrue);
    expect(names['c']!.register('leader', await spawn('c', 'lc')), isTrue);
    await settle();
    expect(holder('a', 'leader'), 'a/la');
    expect(holder('c', 'leader'), 'c/lc');

    network.healAll();
    await settle(400);
    // Node a's name sorts first, so a's actor keeps the name everywhere.
    for (final on in ['a', 'b', 'c']) {
      expect(holder(on, 'leader'), 'a/la', reason: on);
    }
    expect(
        log,
        contains(predicate<String>((l) => l.startsWith(
            'lc got NameConflict(leader, winner: dactor://a/la)'))));
    expect(names['c']!.register('leader', await spawn('c', 'lc2')), isFalse);
  });
}
