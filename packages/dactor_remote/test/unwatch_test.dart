import 'package:dactor/dactor.dart';
import 'package:dactor_remote/dactor_remote.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Unwatching a remote actor, and what a node keeps for the watches other
/// nodes place on its actors.
void main() {
  final log = <String>[];
  late InMemoryNetwork network;
  late TestNode a;
  late TestNode b;
  late ActorRef alice;
  late ActorRef bob;
  late ActorRef bobFromA;

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 30));

  setUp(() async {
    log.clear();
    network = InMemoryNetwork();
    a = join(network, 'a');
    b = join(network, 'b');
    alice = await a.system.spawn('alice', () => Agent('alice', log));
    bob = await b.system.spawn('bob', () => Agent('bob', log));
    b.remote.expose('bob', bob);
    bobFromA = await a.remote.lookup('b', 'bob');
    await alice.ask(LocalMessage(payload: Introduce('bob', bobFromA)));
  });

  tearDown(() async {
    await a.close();
    await b.close();
  });

  test('after unwatch, a remote stop is not reported', () async {
    await alice.ask(LocalMessage(payload: ('watch', 'bob')));
    await settle();
    expect(b.remote.watchedForOthers, 1);
    await alice.ask(LocalMessage(payload: ('unwatch', 'bob')));
    await settle();
    expect(b.remote.watchedForOthers, 0);
    await b.system.stop(bob);
    await settle();
    expect(log.where((l) => l.contains('terminated')), isEmpty);
  });

  test('a node keeps one watch per actor however many watch it there',
      () async {
    final carol = await a.system.spawn('carol', () => Agent('carol', log));
    await carol.ask(LocalMessage(payload: Introduce('bob', bobFromA)));
    await alice.ask(LocalMessage(payload: ('watch', 'bob')));
    await carol.ask(LocalMessage(payload: ('watch', 'bob')));
    await settle();
    expect(b.remote.watchedForOthers, 1);

    // One of two unwatching keeps the watch; the other still hears.
    await alice.ask(LocalMessage(payload: ('unwatch', 'bob')));
    await settle();
    expect(b.remote.watchedForOthers, 1);
    await b.system.stop(bob);
    await settle();
    expect(log, contains('carol saw ${bobFromA.id} terminated: normal'));
    expect(log.where((l) => l.startsWith('alice saw')), isEmpty);
    expect(b.remote.watchedForOthers, 0);
  });

  test('a lost node leaves no watches behind', () async {
    await alice.ask(LocalMessage(payload: ('watch', 'bob')));
    await settle();
    expect(b.remote.watchedForOthers, 1);
    network.partition('a', 'b');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(b.remote.watchedForOthers, 0);
    expect(log, contains('alice saw ${bobFromA.id} terminated: noconnection'));

    // After healing, a new watch works and is counted once.
    network.heal('a', 'b');
    await alice.ask(LocalMessage(payload: ('watch', 'bob')));
    await settle();
    expect(b.remote.watchedForOthers, 1);
    await b.system.stop(bob);
    await settle();
    expect(log.where((l) => l == 'alice saw ${bobFromA.id} terminated: normal'),
        hasLength(1));
  });
}
