import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'transport.dart';

/// A [Transport] over plain TCP sockets.
///
/// **It authenticates nobody and encrypts nothing.** A peer is whoever it
/// says it is, and everything, capability tokens included, crosses the wire
/// in the clear. Use it on one machine, on a network you trust completely,
/// and in tests. Across anything else, use a transport with authenticated
/// peers.
///
/// A node's name is its listening address, `host:port`, which is also how
/// other nodes reach it. Each direction between two nodes has a socket of
/// its own: a node writes on the one it dialled and reads on the one it
/// accepted.
class TcpTransport implements Transport {
  /// Frames larger than this are refused and the connection is closed.
  static const maxFrameBytes = 16 * 1024 * 1024;

  final ServerSocket _server;
  @override
  final String localNode;

  TransportListener? _listener;
  final _outbound = <String, _Outbound>{};
  final _inbound = <String, Set<Socket>>{};
  final _up = <String>{};
  bool _closed = false;

  TcpTransport._(this._server, this.localNode) {
    _server.listen(_accept, onError: (_) {});
  }

  /// Starts listening on [host] and [port] (0 picks a free port).
  /// [advertise] replaces the host in this node's name, for when other
  /// nodes reach it under a different address than the one it binds.
  static Future<TcpTransport> bind(
      {String host = '127.0.0.1', int port = 0, String? advertise}) async {
    final server = await ServerSocket.bind(host, port);
    return TcpTransport._(server, '${advertise ?? host}:${server.port}');
  }

  @override
  void attach(TransportListener listener) => _listener = listener;

  @override
  void send(String node, Uint8List frame) {
    if (_closed) return;
    (_outbound[node] ??= _dial(node)).add(frame);
  }

  _Outbound _dial(String node) {
    final out = _Outbound();
    final colon = node.lastIndexOf(':');
    final port = colon < 0 ? null : int.tryParse(node.substring(colon + 1));
    if (port == null) {
      // Not an address. Fail like any unreachable node, but not re-entrantly.
      scheduleMicrotask(() => _down(node));
      return out;
    }
    Socket.connect(node.substring(0, colon), port,
            timeout: const Duration(seconds: 5))
        .then((socket) {
      if (_closed || !identical(_outbound[node], out)) {
        socket.destroy();
        return;
      }
      socket.setOption(SocketOption.tcpNoDelay, true);
      out.socket = socket;
      // Nothing is read on a dialled socket; listening is how its end is
      // noticed.
      socket.listen((_) {},
          onError: (_) => _down(node), onDone: () => _down(node));
      socket.add(_framed(Uint8List.fromList(utf8.encode(localNode))));
      _nodeUp(node);
      for (final frame in out.waiting) {
        socket.add(_framed(frame));
      }
      out.waiting.clear();
    }, onError: (_) => _down(node));
    return out;
  }

  void _accept(Socket socket) {
    socket.setOption(SocketOption.tcpNoDelay, true);
    String? node;
    final reader = _FrameReader();
    void end() {
      final name = node;
      socket.destroy();
      if (name != null && (_inbound[name]?.remove(socket) ?? false)) {
        _down(name);
      }
    }

    socket.listen((chunk) {
      try {
        for (final frame in reader.add(chunk)) {
          if (node == null) {
            // The first frame says who is calling.
            final name = node = utf8.decode(frame);
            (_inbound[name] ??= {}).add(socket);
            _nodeUp(name);
          } else {
            _listener?.onFrame(node!, frame);
          }
        }
      } on FormatException {
        end();
      }
    }, onError: (_) => end(), onDone: end);
  }

  void _nodeUp(String node) {
    if (_up.add(node)) _listener?.onNodeUp(node);
  }

  /// Ends everything to do with [node] and reports it once.
  void _down(String node) {
    if (_closed) return;
    final out = _outbound.remove(node);
    out?.socket?.destroy();
    final sockets = _inbound.remove(node);
    for (final socket in sockets?.toList() ?? const <Socket>[]) {
      socket.destroy();
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
    // Copies first: destroying a socket can run its handlers at once, and
    // they edit these collections.
    final sockets = [
      for (final out in _outbound.values) out.socket,
      for (final set in _inbound.values) ...set,
    ];
    _outbound.clear();
    _inbound.clear();
    for (final socket in sockets) {
      socket?.destroy();
    }
    _up.clear();
    await _server.close();
  }

  static Uint8List _framed(Uint8List frame) {
    final out = Uint8List(4 + frame.length);
    ByteData.sublistView(out).setUint32(0, frame.length);
    out.setRange(4, out.length, frame);
    return out;
  }
}

class _Outbound {
  Socket? socket;
  final waiting = <Uint8List>[];

  void add(Uint8List frame) {
    final s = socket;
    if (s == null) {
      waiting.add(frame);
    } else {
      s.add(TcpTransport._framed(frame));
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
      if (length > TcpTransport.maxFrameBytes) {
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
