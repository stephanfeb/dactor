import 'dart:async';
import 'dart:typed_data';

import 'package:dactor_remote/dactor_remote.dart';
import 'package:dart_libp2p/dart_libp2p.dart';

/// A [Transport] over a libp2p [Host].
///
/// A node's name is its host's peer id, in base58. Peers are authenticated
/// and traffic is encrypted by whatever security protocol the host was
/// built with (Noise, normally), so a frame that arrives from a node really
/// comes from the holder of that node's key. Capability tokens cross the
/// network encrypted.
///
/// You build and start the host yourself, with the transports, relays and
/// NAT traversal your deployment needs; this class only adds the
/// `/dactor/remote/1.0.0` protocol to it. It does not close the host unless
/// told to.
///
/// To reach a node, libp2p needs an address for it: call [addAddresses]
/// with one, or connect the hosts some other way first (a DHT, mDNS, an
/// earlier connection in the other direction). A node behind a NAT is
/// reached through a relay address, `<relay address>/p2p-circuit/p2p/<id>`.
///
/// Each direction between two nodes is a libp2p stream of its own: a node
/// writes on the stream it opened and reads on the ones it accepted. When
/// either breaks, the node is reported down and the next send opens a new
/// stream. A connection that goes silent is noticed through the muxer's
/// keep-alive, if the host's muxer has one.
class Libp2pTransport implements Transport {
  /// The protocol id the transport registers on the host.
  static const protocol = '/dactor/remote/1.0.0';

  /// Frames larger than this are refused, and the stream that carried one
  /// is closed.
  static const maxFrameBytes = 16 * 1024 * 1024;

  /// The host this transport runs on.
  final Host host;

  /// How long opening a stream to a node may take, dialling included,
  /// before the node is reported down.
  final Duration dialTimeout;

  final bool _ownsHost;

  @override
  final String localNode;

  TransportListener? _listener;
  final _outbound = <String, _Outbound>{};
  final _inbound = <String, Set<P2PStream>>{};
  final _up = <String>{};
  late final Notifiee _notifiee;
  bool _closed = false;

  /// Adds the dactor protocol to [host], which should be started. With
  /// [closeHost], [close] closes the host as well.
  Libp2pTransport(this.host,
      {this.dialTimeout = const Duration(seconds: 15), bool closeHost = false})
      : _ownsHost = closeHost,
        localNode = host.id.toBase58() {
    host.setStreamHandler(protocol, _accept);
    _notifiee = NotifyBundle(disconnectedF: (network, conn) {
      final peer = conn.remotePeer;
      // A peer can have several connections (a relayed one and a direct
      // one); only the last one going means the node is gone.
      if (network.connectedness(peer) != Connectedness.connected) {
        _down(peer.toBase58());
      }
    });
    host.network.notify(_notifiee);
  }

  /// This node's addresses as others can dial them, each ending in
  /// `/p2p/<id>`. Relay addresses appear once a reservation is made.
  List<String> get addresses => [
        for (final addr in host.addrs)
          addr.toString().contains('/p2p/$localNode')
              ? addr.toString()
              : '$addr/p2p/$localNode'
      ];

  /// Tells libp2p where [addresses] reach. Each must end in `/p2p/<id>`,
  /// as [addresses] gives them; the node is the one named there. A relay
  /// address teaches the relay's own address too, which libp2p needs to
  /// dial through it. Returns the node's name.
  Future<String> addAddress(String address,
      {Duration ttl = const Duration(hours: 1)}) async {
    // The node is the last /p2p/ component; in a relay address the first
    // one is the relay.
    final at = address.lastIndexOf('/p2p/');
    if (at < 0) {
      throw ArgumentError.value(
          address, 'address', 'does not end in /p2p/<id>');
    }
    final id = address.substring(at + 5);
    final peer = PeerId.fromString(id);
    final circuit = address.indexOf('/p2p-circuit');
    final MultiAddr addr;
    if (circuit > 0) {
      await addAddress(address.substring(0, circuit), ttl: ttl);
      addr = MultiAddr(address);
    } else {
      addr = MultiAddr(address.substring(0, at));
    }
    await host.peerStore.addrBook.addAddrs(peer, [addr], ttl);
    return id;
  }

  /// [addAddress] for several addresses; returns the nodes' names.
  Future<List<String>> addAddresses(Iterable<String> addresses,
          {Duration ttl = const Duration(hours: 1)}) async =>
      [for (final address in addresses) await addAddress(address, ttl: ttl)];

  @override
  void attach(TransportListener listener) => _listener = listener;

  @override
  void send(String node, Uint8List frame) {
    if (_closed) return;
    (_outbound[node] ??= _open(node)).add(_framed(frame));
  }

  _Outbound _open(String node) {
    final out = _Outbound(this, node);
    final PeerId peer;
    try {
      peer = PeerId.fromString(node);
    } catch (_) {
      // Not a peer id. Fail like any unreachable node, but not re-entrantly.
      scheduleMicrotask(() => _down(node));
      return out;
    }
    host.newStream(peer, const [protocol], Context()).timeout(dialTimeout).then(
        (stream) {
      if (_closed || !identical(_outbound[node], out)) {
        unawaited(stream.reset().catchError((_) {}));
        return;
      }
      out.opened(stream);
      _nodeUp(node);
      // Nothing comes back on an opened stream; reading is how its end is
      // noticed.
      unawaited(_drain(stream, node));
    }, onError: (Object _) {
      if (identical(_outbound[node], out)) _down(node);
    });
    return out;
  }

  Future<void> _drain(P2PStream stream, String node) async {
    try {
      while (!_closed) {
        final chunk = await stream.read();
        if (chunk.isEmpty) break;
      }
    } catch (_) {}
    if (identical(_outbound[node]?.stream, stream)) _down(node);
  }

  Future<void> _accept(P2PStream stream, PeerId remotePeer) async {
    if (_closed) {
      await stream.reset().catchError((_) {});
      return;
    }
    // The security handshake has authenticated the peer; no hello needed.
    final node = remotePeer.toBase58();
    (_inbound[node] ??= {}).add(stream);
    _nodeUp(node);
    final reader = _FrameReader();
    try {
      while (!_closed) {
        final chunk = await stream.read();
        if (chunk.isEmpty) break;
        for (final frame in reader.add(chunk)) {
          if (_closed || !(_inbound[node]?.contains(stream) ?? false)) return;
          _listener?.onFrame(node, frame);
        }
      }
    } catch (_) {
      // A broken stream or an oversized frame: the node is down.
    }
    if (_inbound[node]?.remove(stream) ?? false) {
      unawaited(stream.reset().catchError((_) {}));
      _down(node);
    }
  }

  void _nodeUp(String node) {
    if (_up.add(node)) _listener?.onNodeUp(node);
  }

  /// Ends everything to do with [node] and reports it once.
  void _down(String node) {
    if (_closed) return;
    final out = _outbound.remove(node);
    final streams = [
      if (out?.stream != null) out!.stream!,
      ...?_inbound.remove(node),
    ];
    for (final stream in streams) {
      unawaited(stream.reset().catchError((_) {}));
    }
    // Also reported when the node was never up: that is a send that could
    // not be delivered.
    final wasUp = _up.remove(node);
    if (wasUp || out != null) _listener?.onNodeDown(node);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _listener = null;
    host.removeStreamHandler(protocol);
    host.network.stopNotify(_notifiee);
    final streams = [
      for (final out in _outbound.values)
        if (out.stream != null) out.stream!,
      for (final set in _inbound.values) ...set,
    ];
    _outbound.clear();
    _inbound.clear();
    _up.clear();
    await Future.wait([
      for (final stream in streams) stream.reset().catchError((_) {}),
    ]);
    if (_ownsHost) await host.close();
  }

  static Uint8List _framed(Uint8List frame) {
    final out = Uint8List(4 + frame.length);
    ByteData.sublistView(out).setUint32(0, frame.length);
    out.setRange(4, out.length, frame);
    return out;
  }
}

/// The stream a node writes to another on, and the frames waiting for it.
///
/// Writes are chained so that they reach the stream in order; frames that
/// queue up while one is being written go out together in the next.
class _Outbound {
  final Libp2pTransport _transport;
  final String _node;
  P2PStream? stream;
  final _waiting = BytesBuilder(copy: false);
  bool _writing = false;

  _Outbound(this._transport, this._node);

  void add(Uint8List framed) {
    _waiting.add(framed);
    if (stream != null && !_writing) _flush();
  }

  void opened(P2PStream s) {
    stream = s;
    if (_waiting.isNotEmpty) _flush();
  }

  Future<void> _flush() async {
    _writing = true;
    final s = stream!;
    try {
      while (_waiting.isNotEmpty) {
        await s.write(_waiting.takeBytes());
        if (!identical(stream, s)) return;
      }
    } catch (_) {
      if (identical(_transport._outbound[_node], this)) {
        _transport._down(_node);
      }
    } finally {
      _writing = false;
    }
  }
}

/// Cuts a byte stream back into length-prefixed frames.
class _FrameReader {
  final _buffer = BytesBuilder(copy: false);

  List<Uint8List> add(Uint8List chunk) {
    _buffer.add(chunk);
    if (_buffer.length < 4) return const [];
    final bytes = _buffer.takeBytes();
    final data = ByteData.sublistView(bytes);
    final frames = <Uint8List>[];
    var offset = 0;
    while (bytes.length - offset >= 4) {
      final length = data.getUint32(offset);
      if (length > Libp2pTransport.maxFrameBytes) {
        throw const FormatException('Frame too large');
      }
      if (bytes.length - offset - 4 < length) break;
      frames.add(Uint8List.sublistView(bytes, offset + 4, offset + 4 + length));
      offset += 4 + length;
    }
    if (offset < bytes.length) {
      _buffer.add(Uint8List.sublistView(bytes, offset));
    }
    return frames;
  }
}
