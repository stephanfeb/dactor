/// The part of the mobile probe that is not Flutter: a dactor node on
/// libp2p that reserves a slot on the Ricochet relay, joins the `probe`
/// process group, and checks every other member it finds. The phone app
/// and `bin/peer.dart` (the laptop) both run it.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dactor/dactor.dart';
import 'package:dactor_libp2p/dactor_libp2p.dart';
import 'package:dactor_remote/dactor_remote.dart';
import 'package:dart_libp2p/dart_libp2p.dart'
    show KeyPair, generateEd25519KeyPair, generateEd25519KeyPairFromSeed;

/// The Ricochet server SpiffyVault uses: a public relay.
class Ricochet {
  static const host = 'ricochet.spiffyvault.net';
  static const fallbackIp = '152.42.240.103';
  static const port = 55223;
  static const peerId = '12D3KooWJfrcqqdoAcKUjAB6dGkC9KHCsTG5WKHZH8hk1wLs67it';

  /// The relay's addresses, from DNS (both families: an IPv6-only phone
  /// network reaches it through a synthesised NAT64 address), or the
  /// fallback.
  static Future<List<String>> addresses() async {
    final found = <String>[];
    try {
      for (final a in await InternetAddress.lookup(
        host,
      ).timeout(const Duration(seconds: 3))) {
        final family = a.type == InternetAddressType.IPv6 ? 'ip6' : 'ip4';
        found.add('/$family/${a.address}/udp/$port/udx/p2p/$peerId');
      }
    } catch (_) {
      // No DNS: the fallback below.
    }
    if (found.isEmpty) found.add('/ip4/$fallbackIp/udp/$port/udx/p2p/$peerId');
    return found;
  }
}

/// Asks the receiving probe to ask [target] (the sender's probe) back.
final class AskBack {
  final ActorRef target;
  const AskBack(this.target);
}

CodecRegistry probeCodecs() => CodecRegistry()
  ..register<AskBack>(
    'AskBack',
    encode: (m, ctx) => ctx.encodeRef(m.target),
    decode: (d, ctx) => AskBack(ctx.decodeRef(d)),
  );

final class _Watch {
  final ActorRef member;
  const _Watch(this.member);
}

/// The actor every probe node runs, exposed and in group `probe`.
class ProbeActor extends Actor {
  final String label;
  final void Function(String) log;
  final _next = <String, int>{};
  final _disorder = <String, int>{};
  final _watchedSince = <String, DateTime>{};

  ProbeActor(this.label, this.log);

  void _reply(Object? value) =>
      context.sender?.tell(LocalMessage(payload: value));

  @override
  Future<void> onMessage(dynamic message) async {
    switch (message) {
      case 'ping':
        _reply('pong');
      case 'whoami':
        _reply(label);
      case ['seq', String run, int i]:
        if (i != (_next[run] ?? 0)) {
          _disorder[run] = (_disorder[run] ?? 0) + 1;
        }
        _next[run] = i + 1;
      case ['seqEnd', String run, int n]:
        final got = _next.remove(run) ?? 0;
        final bad = _disorder.remove(run) ?? 0;
        _reply(
          got == n && bad == 0
              ? 'ok'
              : 'last was ${got - 1} of ${n - 1}, $bad gaps',
        );
      case Uint8List blob:
        _reply(blob.length);
      case AskBack(:final target):
        // Not awaited: two probes asking each other back at once would
        // each block its mailbox on the other's and both time out.
        final sender = context.sender;
        void reply(Object? value) => sender?.tell(LocalMessage(payload: value));
        unawaited(
          target
              .ask<String>(
                LocalMessage(payload: 'ping'),
                const Duration(seconds: 20),
              )
              .then(reply, onError: (Object e) => reply('failed: $e')),
        );
      case ['report', String from, String line]:
        log('[$from] $line');
      case _Watch(:final member):
        _watchedSince[member.id] = DateTime.now();
        context.watch(member);
      case Terminated(:final actor, :final reason):
        log('watch: ${short(actor.id)} ended (${reason.runtimeType})');
    }
  }
}

String short(String id) {
  final node = id.startsWith('dactor://') ? id.substring(9) : id;
  final slash = node.indexOf('/');
  final peer = slash < 0 ? node : node.substring(0, slash);
  return peer.length > 10 ? '…${peer.substring(peer.length - 6)}' : peer;
}

String ms(Duration d) => '${d.inMilliseconds} ms';

/// One probe node.
class Probe {
  final String label;
  final LocalActorSystem system;
  final Libp2pTransport transport;
  final RemoteNode node;
  final ProcessGroups groups;
  final ActorRef actor;
  final void Function(String) _sink;
  final bool autoCheck;
  ActorRef? seed;
  final _labels = <String, String>{};
  final _checking = <String>{};
  final _random = Random();
  final _subscriptions = <StreamSubscription<Object?>>[];

  Probe._(
    this.label,
    this.system,
    this.transport,
    this.node,
    this.groups,
    this.actor,
    this._sink,
    this.autoCheck,
  );

  /// Starts a probe node: reserves on Ricochet, joins group `probe`, and
  /// with [seedUri] connects to the node behind it.
  ///
  /// [stateSeed] (64 bytes) keeps the node's key and capability secret
  /// across restarts: the first 32 bytes seed the key, the rest are the
  /// secret.
  static Future<Probe> start({
    required String label,
    required void Function(String) log,
    String? seedUri,
    Uint8List? stateSeed,
    bool autoCheck = true,
  }) async {
    final started = DateTime.now();
    final relays = await Ricochet.addresses();
    log('relay ${relays.join(' or ')}');
    final KeyPair keys = stateSeed == null
        ? await generateEd25519KeyPair()
        : await generateEd25519KeyPairFromSeed(stateSeed.sublist(0, 32));
    final host = await startHost(
      keyPair: keys,
      relay: RelayRole.reserve,
      relays: relays,
      holePunching: true,
      observersNeeded: 1,
      keepAlive: const Duration(seconds: 5),
      keepAliveTimeout: const Duration(seconds: 15),
    );
    final transport = Libp2pTransport(
      host,
      closeHost: true,
      dialTimeout: const Duration(seconds: 15),
    );
    final system = LocalActorSystem(
      ActorSystemConfig(logCollector: const NoOpLogCollector()),
    );
    final node = RemoteNode(
      system,
      transport,
      codecs: probeCodecs(),
      secret: stateSeed?.sublist(32),
      defaultTimeout: const Duration(seconds: 20),
    );
    void stamped(String line) {
      final t = DateTime.now().toIso8601String().substring(11, 23);
      log('$t $line');
    }

    final actor = await system.spawn('probe', () => ProbeActor(label, stamped));
    node.expose('probe', actor);
    final groups = ProcessGroups(
      node,
      scope: 'probe',
      retry: const Duration(seconds: 3),
    );
    final probe = Probe._(
      label,
      system,
      transport,
      node,
      groups,
      actor,
      stamped,
      autoCheck,
    );
    probe._watch();
    groups.join('probe', actor);

    stamped('$label is ${short(node.id)} (${node.id})');
    final reserved = await probe._waitForReservation();
    stamped(
      reserved
          ? 'relay slot after ${ms(DateTime.now().difference(started))}'
          : 'no relay slot after 30 s; carrying on',
    );
    if (seedUri != null && seedUri.isNotEmpty) {
      final seed = node.resolve(seedUri);
      probe.seed = seed;
      groups.connect((seed as RemoteRef).node);
      stamped('seed is ${short(seed.id)}');
    }
    return probe;
  }

  /// This probe's reference as text, with its addresses.
  String get uri => node.uriOf(actor);

  Future<bool> _waitForReservation() async {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline)) {
      if (transport.localAddresses.any((a) => a.contains('p2p-circuit'))) {
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return false;
  }

  void _watch() {
    _subscriptions.add(
      node.events.listen((event) {
        final who = _name(event.node);
        switch (event) {
          case NodeUp():
            log('node up: $who via ${_route(event.node)}');
          case NodeDown():
            log('node down: $who');
        }
      }),
    );
    _subscriptions.add(
      groups.changes.listen((change) {
        for (final member in change.joined) {
          if (member is! RemoteRef) continue;
          log('member joined: ${_name(member.node)}');
          actor.tell(LocalMessage(payload: _Watch(member)));
          if (autoCheck) unawaited(check(member));
        }
        for (final member in change.left) {
          if (member is RemoteRef) log('member left: ${_name(member.node)}');
        }
      }),
    );
  }

  String _name(String node) {
    final label = _labels[node];
    return label == null ? short(node) : '$label(${short(node)})';
  }

  String _route(String node) {
    final route = transport.routeTo(node);
    if (route == null) return 'no stream yet';
    return route.contains('p2p-circuit') ? 'relay' : 'direct $route';
  }

  /// Logs [line] here and reports it to the seed.
  void log(String line) {
    _sink(line);
    final seed = this.seed;
    if (seed != null) {
      seed.tell(LocalMessage(payload: ['report', label, line]));
    }
  }

  /// Every other member of group `probe`, checked one after another.
  Future<void> checkAll() async {
    for (final member in groups.members('probe')) {
      if (member is RemoteRef) await check(member);
    }
  }

  /// The checks of the NAT harness against [peer]'s probe: ask, round
  /// trip, 5,000 ordered messages, 1 MiB, and an ask back.
  Future<void> check(RemoteRef peer) async {
    if (!_checking.add(peer.node)) return;
    try {
      final watch = Stopwatch()..start();
      final label = await peer.ask<String>(LocalMessage(payload: 'whoami'));
      _labels[peer.node] = label;
      final who = _name(peer.node);
      log(
        'check $who: first ask ${ms(watch.elapsed)}, '
        'via ${_route(peer.node)}',
      );

      final rtts = <int>[];
      for (var i = 0; i < 10; i++) {
        watch.reset();
        await peer.ask<String>(LocalMessage(payload: 'ping'));
        rtts.add(watch.elapsedMicroseconds);
      }
      rtts.sort();
      log(
        'check $who: ask median ${(rtts[5] / 1000).toStringAsFixed(1)} ms, '
        'max ${(rtts.last / 1000).toStringAsFixed(1)} ms',
      );

      final run = '$label-${_random.nextInt(1 << 30)}';
      const count = 5000;
      watch.reset();
      for (var i = 0; i < count; i++) {
        peer.tell(LocalMessage(payload: ['seq', run, i]));
      }
      final order = await peer.ask<String>(
        LocalMessage(payload: ['seqEnd', run, count]),
        const Duration(seconds: 120),
      );
      log('check $who: $count in order: $order in ${ms(watch.elapsed)}');

      watch.reset();
      final size = await peer.ask<int>(
        LocalMessage(payload: Uint8List(1 << 20)),
        const Duration(seconds: 120),
      );
      log(
        'check $who: 1 MiB: ${size == 1 << 20 ? 'ok' : 'got $size'} '
        'in ${ms(watch.elapsed)}',
      );

      watch.reset();
      final back = await peer.ask<String>(
        LocalMessage(payload: AskBack(actor)),
        const Duration(seconds: 30),
      );
      log(
        'check $who: asked back: $back in ${ms(watch.elapsed)}, '
        'now via ${_route(peer.node)}',
      );
    } catch (e) {
      log('check ${_name(peer.node)} failed: $e');
    } finally {
      _checking.remove(peer.node);
    }
  }

  Future<void> close() async {
    for (final s in _subscriptions) {
      unawaited(s.cancel());
    }
    await groups.close();
    await node.close();
    await system.shutdown();
  }
}
