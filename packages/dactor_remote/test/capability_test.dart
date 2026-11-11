import 'dart:typed_data';

import 'package:dactor/dactor.dart';
import 'package:dactor_remote/dactor_remote.dart';
import 'package:test/test.dart';

import 'support.dart';

/// A peer that speaks the wire format by hand, to send what an honest node
/// never would.
class RawPeer implements TransportListener {
  final Transport transport;
  final frames = <Map<Object?, Object?>>[];
  RawPeer(this.transport) {
    transport.attach(this);
  }

  void send(String node, Map<int, Object?> frame) =>
      transport.send(node, cborEncode(frame));

  void sendBytes(String node, List<int> bytes) =>
      transport.send(node, Uint8List.fromList(bytes));

  @override
  void onFrame(String from, Uint8List frame) =>
      frames.add(cborDecode(frame) as Map);

  @override
  void onNodeDown(String node) {}

  @override
  void onNodeUp(String node) {}
}

// Wire constants, as in remote_node.dart.
const kind = 0, type = 1, version = 2, path = 3, correlation = 5;
const payload = 9, capability = 10, other = 12, reason = 13;
const message = 0, reply = 1, watch = 2, terminated = 4, link = 5, exit = 7;

void main() {
  late InMemoryNetwork network;
  late TestNode a;
  late RawPeer mallory;
  late InMemoryMetricsCollector metrics;
  final log = <String>[];

  setUp(() {
    log.clear();
    network = InMemoryNetwork(detectAfter: const Duration(milliseconds: 30));
    metrics = InMemoryMetricsCollector();
    a = join(network, 'a',
        system: LocalActorSystem(ActorSystemConfig(
            metricsCollector: metrics,
            logCollector: const NoOpLogCollector())));
    mallory = RawPeer(network.join('mallory'));
  });

  tearDown(() => a.close());

  Future<void> settle([int ms = 30]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  Map<int, Object?> text(String to, String body, {Object? cap}) => {
        kind: message,
        path: to,
        capability: cap,
        type: '',
        version: 1,
        payload: body,
      };

  test('an actor nobody was given a reference to cannot be reached', () async {
    await a.system.spawn('secret', () => Agent('secret', log));
    mallory.send('a', text('secret', 'guessed your id'));
    mallory.send('a', text('secret', 'made up a token', cap: Uint8List(16)));
    mallory.send('a', text('secret', 'short token', cap: Uint8List(3)));
    mallory.send('a', text('secret', 'token of the wrong type', cap: 'abc'));
    await settle();
    expect(log, ['secret started']);
    expect(metrics.getCounter('remote.frames.unauthorized'), 4);
  });

  test('a token opens the actor it was made for and no other', () async {
    final open = await a.system.spawn('open', () => Agent('open', log));
    await a.system.spawn('secret', () => Agent('secret', log));
    a.remote.expose('open', open);

    // Mallory looks up the exposed actor, as anyone may.
    mallory.send('a', {kind: 8, correlation: 1, 15: 'open'});
    await settle();
    final answer = mallory.frames.single;
    expect(answer[kind], reply);
    final [node, actorPath, token as Uint8List] = answer[payload] as List;
    expect([node, actorPath], ['a', 'open']);

    mallory.send('a', text('open', 'with my token', cap: token));
    mallory.send('a', text('secret', 'with a borrowed token', cap: token));
    await settle();
    expect(log, contains('open got with my token'));
    expect(log, isNot(contains('secret got with a borrowed token')));
  });

  test('watch and link need a token too', () async {
    await a.system.spawn('secret', () => Agent('secret', log, trap: true));
    mallory.send('a', {kind: watch, path: 'secret'});
    mallory.send('a', {kind: link, path: 'secret', other: 'm'});
    await settle();
    expect(metrics.getCounter('remote.frames.unauthorized'), 2);
    // Told "no such actor", which is also what a missing actor looks like.
    expect(mallory.frames.map((f) => f[kind]), [terminated, exit]);

    // And no link was made: killing the connection signals nothing.
    network.partition('a', 'mallory');
    await settle(80);
    expect(log, ['secret started']);
  });

  test('an exit signal counts only from a linked actor', () async {
    final victim = await a.system.spawn('victim', () => Agent('victim', log));
    mallory.send('a', {
      kind: exit,
      path: 'victim',
      other: 'anything',
      reason: [2]
    });
    await settle();
    expect(victim.isAlive, isTrue);
  });

  test('a death notice counts only for an actor being watched', () async {
    final b = join(network, 'b');
    addTearDown(b.close);
    b.remote
        .expose('bob', await b.system.spawn('bob', () => Agent('bob', log)));
    final alice = await a.system.spawn('alice', () => Agent('alice', log));
    final bob = await a.remote.lookup('b', 'bob');
    await alice.ask<String>(LocalMessage(payload: Introduce('bob', bob)));
    await alice.ask<String>(LocalMessage(payload: ('watch', 'bob')));
    await settle();

    // Mallory claims bob is dead. Alice watches bob on b, not on mallory.
    mallory.send('a', {
      kind: terminated,
      path: 'bob',
      reason: [2]
    });
    await settle();
    expect(log.where((l) => l.contains('terminated')), isEmpty);
  });

  test('a reply counts only from the node that was asked', () async {
    final b = join(network, 'b');
    addTearDown(b.close);
    b.remote
        .expose('bob', await b.system.spawn('bob', () => Agent('bob', log)));
    final bob = await a.remote.lookup('b', 'bob');

    // Connect mallory, then race her forged replies against the real one.
    mallory.send('a', {kind: 99});
    await settle();
    final asked = bob.ask<String>(LocalMessage(payload: 'ping'));
    for (var guess = 0; guess < 20; guess++) {
      mallory.send('a', {
        kind: reply,
        correlation: guess,
        type: '',
        version: 1,
        payload: 'forged'
      });
    }
    expect(await asked, 'pong from bob');
  });

  test('garbage does not break the node', () async {
    final open = await a.system.spawn('open', () => Agent('open', log));
    a.remote.expose('open', open);
    mallory.sendBytes('a', []);
    mallory.sendBytes('a', [0xff, 0xff, 0xff]);
    mallory.sendBytes('a', [0x9b, 0, 0, 0, 0, 0xff, 0xff, 0xff, 0xff]);
    mallory.send('a', {kind: 'not a number'});
    mallory.send('a', {kind: message});
    mallory.send('a', {kind: message, path: 42});
    mallory.send('a', {kind: reply, correlation: 'x'});
    mallory.send('a', {kind: 9, correlation: 'x', 15: 3});
    mallory.send('a', {
      kind: message,
      path: 'open',
      capability: null,
      type: 'NoSuchType',
      version: 7,
      payload: null
    });
    await settle();
    expect(metrics.getCounter('remote.frames.rejected'), greaterThan(5));

    // Still serving honest peers.
    final b = join(network, 'b');
    addTearDown(b.close);
    final ref = await b.remote.lookup('a', 'open');
    expect(
        await ref.ask<String>(LocalMessage(payload: 'ping')), 'pong from open');
  });

  test('tokens die with the secret, and live on with it', () async {
    final secret = List<int>.generate(32, (i) => i);
    LocalActorSystem system() => LocalActorSystem(
        ActorSystemConfig(logCollector: const NoOpLogCollector()));

    Future<(TestNode, String)> start(String name, List<int>? key) async {
      final s = system();
      final node = TestNode(
          s, RemoteNode(s, network.join(name), codecs: codecs(), secret: key));
      final ref = await s.spawn('svc', () => Agent('svc', log));
      return (node, node.remote.uriOf(ref));
    }

    // The same secret after a restart: an address from before still works.
    final (first, address) = await start('stable', secret);
    await first.close();
    final (second, _) = await start('stable', secret);
    addTearDown(second.close);
    expect(
        await a.remote
            .resolve(address)
            .ask<String>(LocalMessage(payload: 'ping')),
        'pong from svc');

    // A new secret: the old address is refused.
    final (third, old) = await start('fresh', null);
    await third.close();
    final (fourth, _) = await start('fresh', null);
    addTearDown(fourth.close);
    await expectLater(
        a.remote.resolve(old).ask<String>(LocalMessage(payload: 'ping')),
        throwsStateError);
  });

  test('with capabilities off, an id is enough', () async {
    final open = join(network, 'open', requireCapabilities: false);
    addTearDown(open.close);
    await open.system.spawn('anyone', () => Agent('anyone', log));
    mallory.send('open', text('anyone', 'hello'));
    await settle();
    expect(log, contains('anyone got hello'));
  });
}
