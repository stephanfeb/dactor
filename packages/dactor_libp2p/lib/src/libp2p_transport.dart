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
/// To reach a node, libp2p needs an address for it. The transport is an
/// [AddressBook], so `RemoteNode` passes addresses along with references
/// and process groups pass them between the nodes of a scope: a node that
/// was handed a reference can usually dial its node. Otherwise, call
/// [addAddresses], give a [resolve] function (a DHT lookup, for example),
/// or connect the hosts some other way first. A node behind a NAT is
/// reached through a relay address, `<relay address>/p2p-circuit/p2p/<id>`.
///
/// Each direction between two nodes is a libp2p stream of its own: a node
/// writes on the stream it opened and reads on the ones it accepted. When
/// either breaks, the node is reported down and the next send opens a new
/// stream. A connection that goes silent is noticed through the muxer's
/// keep-alive, if the host's muxer has one.
///
/// When a direct connection to a node appears while frames to it go over a
/// relay (a hole punch succeeded, or the node was dialled directly), the
/// transport moves them to a stream on the direct connection. It ends the
/// old stream with a marker (an empty frame), and the receiving side reads
/// a node's newer stream only after the older one has ended with it, so
/// frames keep their order and the node is not reported down.
class Libp2pTransport implements Transport, AddressBook {
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

  /// Asked for a node's addresses before dialling it, when none are known.
  /// Returns addresses ending in `/p2p/<id>`; an empty list when it finds
  /// none.
  final Future<List<String>> Function(String node)? resolve;

  /// Which of this node's addresses [localAddresses] passes on to others.
  /// By default, those this node could dial itself: a relay reachable over
  /// TCP is left out when the host has only UDX, for example, on the
  /// assumption that the other nodes run the same transports.
  final bool Function(String address)? advertise;

  // Addresses known per node, each ending in /p2p/<node>: those added or
  // learned, and those a node listed when identified.
  final _addressesOf = <String, List<String>>{};
  // Addresses being written to the peer store, by node; a dial waits for
  // them.
  final _storing = <String, Future<void>>{};
  Subscription? _identified;

  @override
  final String localNode;

  TransportListener? _listener;
  final _outbound = <String, _Outbound>{};
  final _inbound = <String, List<_Inbound>>{};
  final _up = <String>{};
  late final Notifiee _notifiee;
  bool _closed = false;

  /// Adds the dactor protocol to [host], which should be started. With
  /// [closeHost], [close] closes the host as well.
  Libp2pTransport(this.host,
      {this.dialTimeout = const Duration(seconds: 15),
      bool closeHost = false,
      this.resolve,
      this.advertise})
      : _ownsHost = closeHost,
        localNode = host.id.toBase58() {
    host.setStreamHandler(protocol, _accept);
    _identified = host.eventBus.subscribe(EvtPeerIdentificationCompleted);
    _identified!.stream.listen((event) {
      if (event
          case EvtPeerIdentificationCompleted(
            :final peer,
            :final listenAddrs
          )) {
        final node = peer.toBase58();
        _remember(node, [for (final a in listenAddrs) _withPeer('$a', node)]);
      }
    });
    _notifiee = NotifyBundle(connectedF: (network, conn, {dialLatency}) {
      if (!_isRelayed(conn)) {
        final node = conn.remotePeer.toBase58();
        scheduleMicrotask(() => _moveOffRelay(node));
      }
    }, disconnectedF: (network, conn) {
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

  @override
  List<String> get localAddresses => [
        for (final address in addresses)
          if (advertise?.call(address) ?? _canDial(address)) address
      ];

  /// Whether this host could dial [address], or for a relay address, the
  /// relay in it.
  bool _canDial(String address) {
    try {
      final circuit = address.indexOf('/p2p-circuit');
      final target = circuit < 0 ? address : address.substring(0, circuit);
      final at = target.lastIndexOf('/p2p/');
      if (at < 0) return false;
      return host.network.canDial(PeerId.fromString(target.substring(at + 5)),
          MultiAddr(target.substring(0, at)));
    } catch (_) {
      return false;
    }
  }

  @override
  List<String> addressesOf(String node) => _addressesOf[node] ?? const [];

  @override
  void learn(String node, List<String> addresses) {
    final usable = [
      for (final a in addresses)
        if (a.endsWith('/p2p/$node')) a
    ];
    if (usable.isEmpty || node == localNode) return;
    _store(node, usable);
  }

  void _store(String node, List<String> addresses) {
    _remember(node, addresses);
    final before = _storing[node] ?? Future<void>.value();
    late final Future<void> done;
    done = before.then((_) async {
      for (final a in addresses) {
        try {
          await addAddress(a);
        } catch (_) {
          // Not an address libp2p can parse; dialling will do without it.
        }
      }
    }).whenComplete(() {
      if (identical(_storing[node], done)) _storing.remove(node);
    });
    _storing[node] = done;
  }

  /// Keeps [addresses] first among those known for [node], at most
  /// [RemoteNode.maxAddresses] of them.
  void _remember(String node, List<String> addresses) {
    if (node == localNode || addresses.isEmpty) return;
    final known = _addressesOf[node] ?? const [];
    _addressesOf[node] = {...addresses, ...known}
        .take(RemoteNode.maxAddresses)
        .toList(growable: false);
  }

  static String _withPeer(String address, String node) =>
      address.endsWith('/p2p/$node') ? address : '$address/p2p/$node';

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
    _remember(id, [address]);
    return id;
  }

  /// The remote address of the connection that frames to [node] go over,
  /// or null when none is open. A relayed one contains `/p2p-circuit`.
  String? routeTo(String node) =>
      _outbound[node]?.stream?.conn.remoteMultiaddr.toString();

  static bool _isRelayed(Conn conn) =>
      conn.remoteMultiaddr.toString().contains('/p2p-circuit');

  /// Moves frames to [node] onto a direct connection, if they go over a
  /// relay and libp2p now opens streams to it directly.
  void _moveOffRelay(String node) {
    final out = _outbound[node];
    final current = out?.stream;
    if (_closed || out == null || current == null || out.moving) return;
    if (!_isRelayed(current.conn)) return;
    out.moving = true;
    host
        .newStream(PeerId.fromString(node), const [protocol], Context())
        .timeout(dialTimeout)
        .then((stream) {
      if (_closed ||
          !identical(_outbound[node], out) ||
          _isRelayed(stream.conn)) {
        out.moving = false;
        unawaited(stream.reset().catchError((_) {}));
        return;
      }
      unawaited(_drain(stream, node));
      out.moveTo(stream);
    }, onError: (Object _) => out.moving = false);
  }

  /// [addAddress] for several addresses; returns the nodes' names.
  Future<List<String>> addAddresses(Iterable<String> addresses,
          {Duration ttl = const Duration(hours: 1)}) async =>
      [for (final address in addresses) await addAddress(address, ttl: ttl)];

  @override
  void attach(TransportListener listener) => _listener = listener;

  @override
  void send(String node, Uint8List frame) {
    // An empty frame is the handover marker; dactor_remote never sends one.
    if (_closed || frame.isEmpty) return;
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
    _dialable(node, peer)
        .then((_) => host.newStream(peer, const [protocol], Context()))
        .timeout(dialTimeout)
        .then((stream) {
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

  /// Waits for addresses of [node] still being stored, and asks [resolve]
  /// when there are none at all and no connection either.
  Future<void> _dialable(String node, PeerId peer) async {
    await _storing[node];
    final resolve = this.resolve;
    if (resolve == null ||
        host.network.connectedness(peer) == Connectedness.connected ||
        (await host.peerStore.addrBook.addrs(peer)).isNotEmpty) {
      return;
    }
    learn(node, await resolve(node));
    await _storing[node];
  }

  Future<void> _drain(P2PStream stream, String node) async {
    try {
      while (!_closed) {
        final chunk = await _read(stream);
        if (chunk.isEmpty) break;
      }
    } catch (_) {}
    if (identical(_outbound[node]?.stream, stream)) _down(node);
  }

  /// Reads from [stream], waiting for as long as the stream lasts.
  ///
  /// Without a deadline, a Yamux read gives up after five minutes without
  /// data and throws, though the stream is fine: a node that sent nothing
  /// for five minutes would be taken for down. Whether the connection
  /// still works is the keep-alive's to find out, which then ends the
  /// stream. The deadline is set before every read: libp2p clears it on an
  /// accepted stream once protocol negotiation is done, which can be after
  /// the handler has started.
  static Future<dynamic> _read(P2PStream stream) async {
    try {
      await stream.setReadDeadline(_noDeadline);
    } catch (_) {
      // A stream without deadlines has no five-minute limit either.
    }
    return stream.read();
  }

  static final _noDeadline = DateTime.utc(9999);

  Future<void> _accept(P2PStream stream, PeerId remotePeer) async {
    if (_closed) {
      await stream.reset().catchError((_) {});
      return;
    }
    // The security handshake has authenticated the peer; no hello needed.
    final node = remotePeer.toBase58();
    final entry = _Inbound(stream);
    final queue = _inbound[node] ??= [];
    final before = queue.lastOrNull;
    queue.add(entry);
    _nodeUp(node);
    // Frames move to a new stream only after the old one ended with the
    // handover marker; until then, this stream waits unread.
    if (before != null && !await before.handedOver.future) return;
    final reader = _FrameReader();
    var handedOver = false;
    try {
      read:
      while (!_closed) {
        final chunk = await _read(stream);
        if (chunk.isEmpty) break;
        for (final frame in reader.add(chunk)) {
          if (_closed || !(_inbound[node]?.contains(entry) ?? false)) return;
          if (frame.isEmpty) {
            handedOver = true;
            break read;
          }
          _listener?.onFrame(node, frame);
        }
      }
    } catch (_) {
      // A broken stream or an oversized frame: the node is down.
    }
    if (!(_inbound[node]?.remove(entry) ?? false)) return;
    entry.handedOver.complete(handedOver);
    if (handedOver) {
      unawaited(stream.close().catchError((_) {}));
    } else {
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
    final inbound = _inbound.remove(node) ?? const <_Inbound>[];
    for (final entry in inbound) {
      if (!entry.handedOver.isCompleted) entry.handedOver.complete(false);
    }
    final streams = [
      if (out?.stream != null) out!.stream!,
      if (out?.next != null) out!.next!,
      for (final entry in inbound) entry.stream,
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
    unawaited(_identified?.close().catchError((_) {}));
    final streams = [
      for (final out in _outbound.values) ...[
        if (out.stream != null) out.stream!,
        if (out.next != null) out.next!,
      ],
      for (final queue in _inbound.values)
        for (final entry in queue) entry.stream,
    ];
    for (final queue in _inbound.values) {
      for (final entry in queue) {
        if (!entry.handedOver.isCompleted) entry.handedOver.complete(false);
      }
    }
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

/// A stream a node accepted, and whether it ended by handing over to the
/// node's next stream (true) or otherwise (false).
class _Inbound {
  final P2PStream stream;
  final handedOver = Completer<bool>();
  _Inbound(this.stream);
}

/// The stream a node writes to another on, and the frames waiting for it.
///
/// Writes are chained so that they reach the stream in order; frames that
/// queue up while one is being written go out together in the next.
class _Outbound {
  /// The handover marker: a frame of length zero.
  static final _marker = Uint8List(4);

  final Libp2pTransport _transport;
  final String _node;
  P2PStream? stream;

  /// A stream to move to, at the next frame boundary.
  P2PStream? next;

  /// A move is being prepared or is waiting in [next].
  bool moving = false;

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

  void moveTo(P2PStream s) {
    next = s;
    if (!_writing) _flush();
  }

  Future<void> _flush() async {
    _writing = true;
    try {
      while (true) {
        final to = next;
        if (to != null) {
          // Everything written so far is on the old stream; the marker
          // tells the other side to continue with the next one.
          await stream!.write(_marker);
          final old = stream!;
          stream = to;
          next = null;
          moving = false;
          unawaited(old.closeWrite().catchError((_) {}));
        }
        if (_waiting.isEmpty) break;
        await stream!.write(_waiting.takeBytes());
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
