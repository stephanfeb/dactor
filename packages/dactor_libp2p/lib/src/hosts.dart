import 'package:dart_libp2p/config/config.dart';
import 'package:dart_libp2p/dart_libp2p.dart' hide Option;
import 'package:dart_libp2p/p2p/security/noise/noise_protocol.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart';
import 'package:dart_libp2p/p2p/transport/multiplexing/multiplexer.dart';
import 'package:dart_libp2p/p2p/transport/multiplexing/yamux/session.dart';
import 'package:dart_libp2p/p2p/transport/udx_transport.dart';

/// What a node does about relays.
enum RelayRole {
  /// Neither uses nor offers relays, and cannot dial relay addresses.
  none,

  /// Can dial other nodes through relay addresses, but makes no
  /// reservation of its own.
  client,

  /// Makes a reservation with the relays it is given, so that nodes that
  /// cannot dial it directly (it is behind a NAT) reach it through them.
  reserve,

  /// Relays for others. Should be publicly reachable.
  server,
}

/// Builds and starts a libp2p host the way dactor_libp2p's tests and
/// examples use it: UDX (over UDP), Noise, Yamux with keep-alive.
///
/// For anything this does not cover, build the host with `Libp2p.new_`
/// yourself and hand it to `Libp2pTransport`; see the package README.
///
/// - [keyPair]: the node's identity, and so its name. A new one when null;
///   pass a stored one for a node whose name must survive a restart.
/// - [listen]: multiaddresses to listen on. Empty for a node that is only
///   reached through relays or connections it opens.
/// - [relay] and [relays]: see [RelayRole]. [relays] are relay addresses
///   ending in `/p2p/<id>`, needed for [RelayRole.reserve].
/// - [holePunching]: try to replace a relayed connection with a direct one.
///   A punch needs this node's public address, which it learns from the
///   peers that observe it: [observersNeeded] of them must report the same
///   address before it is used (libp2p's default is 4). A node that only
///   ever talks to its relay has one observer, and never punches unless
///   this is 1. A lower number trusts fewer peers about where this node
///   is.
/// - [announce]: which of its addresses the node tells peers about. When
///   given, it replaces libp2p's default filter (which drops loopback
///   addresses unless [allowLoopback]). Use it, for example, to keep LAN
///   addresses private and advertise only relay addresses.
/// - [keepAlive] and [keepAliveTimeout]: how often Yamux pings a
///   connection, and how long a ping may go unanswered before the
///   connection is closed and the node reported down. The timeout is what
///   bounds how long a node that vanished silently (a killed process, a
///   phone out of signal) goes unnoticed; UDX's own idle timeout, 30 s,
///   is the backstop.
Future<Host> startHost({
  KeyPair? keyPair,
  List<String> listen = const ['/ip4/0.0.0.0/udp/0/udx'],
  RelayRole relay = RelayRole.client,
  List<String> relays = const [],
  bool holePunching = false,
  int observersNeeded = 4,
  bool allowLoopback = false,
  bool Function(String address)? announce,
  Duration keepAlive = const Duration(seconds: 15),
  Duration keepAliveTimeout = const Duration(seconds: 30),
}) async {
  if (relay == RelayRole.reserve && relays.isEmpty) {
    throw ArgumentError('RelayRole.reserve needs at least one relay');
  }
  final keys = keyPair ?? await generateEd25519KeyPair();
  final connections = ConnectionManager();
  final muxing = MultiplexerConfig(
    keepAliveInterval: keepAlive,
    keepAliveTimeout: keepAliveTimeout,
    maxStreamWindowSize: 1024 * 1024,
    initialStreamWindowSize: 256 * 1024,
    streamWriteTimeout: const Duration(seconds: 10),
    maxStreams: 256,
  );
  final host = await Libp2p.new_([
    Libp2p.identity(keys),
    Libp2p.connManager(connections),
    Libp2p.transport(UDXTransport(connManager: connections)),
    Libp2p.security(await NoiseSecurity.create(keys)),
    Libp2p.muxer(
        '/yamux/1.0.0',
        (conn, isClient) =>
            YamuxSession(conn as TransportConn, muxing, isClient, null)),
    Libp2p.listenAddrs([for (final a in listen) MultiAddr(a)]),
    if (announce != null)
      Libp2p.addrsFactory(
          (addrs) => addrs.where((a) => announce(a.toString())).toList())
    else if (allowLoopback)
      Libp2p.addrsFactory((addrs) => addrs),
    Libp2p.autoNAT(false),
    if (relay != RelayRole.none) Libp2p.relay(true),
    if (relay == RelayRole.server)
      Libp2p.forceReachability(Reachability.public),
    if (relay == RelayRole.reserve) ...[
      Libp2p.autoRelay(true),
      Libp2p.relayServers(relays),
      Libp2p.forceReachability(Reachability.private),
    ],
    if (holePunching) Libp2p.holePunching(true),
    Libp2p.observedAddrActivationThreshold(observersNeeded),
  ]);
  await host.start();
  return host;
}
