import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

import 'transport.dart';

/// A network inside one isolate, for tests.
///
/// Nodes [join] it and get a [Transport]. Frames travel with a configurable
/// delay, and the test can cut and restore the path between any two nodes.
/// Everything is driven by timers, so inside a dactor simulation the whole
/// network runs on virtual time and is replayed exactly from the seed.
class InMemoryNetwork {
  /// How long a frame travels.
  final Duration latency;

  /// Extra random delay per frame, up to this much. Frames between two
  /// nodes still arrive in order.
  final Duration jitter;

  /// How long after a partition the two sides notice that the connection is
  /// gone, and how long a send to an unreachable node takes to fail.
  final Duration detectAfter;

  final Random _random;
  final _nodes = <String, _MemoryTransport>{};
  final _cut = <(String, String)>{};
  final _connected = <(String, String)>{};

  /// Pairs whose connection was cut and is not yet reported lost. Nothing
  /// passes between them until it is, even if the path heals first:
  /// otherwise frames sent after a heal would arrive after frames lost in
  /// the cut, with no word of the loss.
  final _broken = <(String, String)>{};

  /// Senders whose frames to a node were dropped because it could not be
  /// reached, until that is reported to them; their further frames to it
  /// are dropped too, for the same reason.
  final _failing = <(String, String)>{};

  /// With [random] from `Simulation.random`, jitter is replayed with the
  /// seed.
  InMemoryNetwork({
    this.latency = const Duration(milliseconds: 1),
    this.jitter = Duration.zero,
    this.detectAfter = const Duration(milliseconds: 200),
    Random? random,
  }) : _random = random ?? Random();

  /// Adds a node called [name] and returns its transport.
  Transport join(String name) {
    if (_nodes.containsKey(name)) {
      throw ArgumentError.value(name, 'name', 'is already on the network');
    }
    return _nodes[name] = _MemoryTransport(this, name);
  }

  static (String, String) _pair(String a, String b) =>
      a.compareTo(b) <= 0 ? (a, b) : (b, a);

  /// Cuts the path between [a] and [b], in both directions. Frames in
  /// flight are lost. If the two were connected, both learn of it after
  /// [detectAfter].
  void partition(String a, String b) {
    final pair = _pair(a, b);
    if (!_cut.add(pair)) return;
    _nodes[a]?._flight[b]?.clear();
    _nodes[b]?._flight[a]?.clear();
    if (_connected.contains(pair) && _broken.add(pair)) {
      Timer(detectAfter, () => _disconnect(a, b));
    }
  }

  /// Restores the path between [a] and [b]. Nothing reconnects by itself;
  /// the next send does.
  void heal(String a, String b) => _cut.remove(_pair(a, b));

  /// Cuts [node] off from every other node.
  void isolate(String node) {
    for (final other in _nodes.keys.toList()) {
      if (other != node) partition(node, other);
    }
  }

  /// Restores every path.
  void healAll() => _cut.clear();

  bool isPartitioned(String a, String b) => _cut.contains(_pair(a, b));

  void _disconnect(String a, String b) {
    _broken.remove(_pair(a, b));
    if (!_connected.remove(_pair(a, b))) return;
    _nodes[a]?._flight[b]?.clear();
    _nodes[b]?._flight[a]?.clear();
    _nodes[a]?._listener?.onNodeDown(b);
    _nodes[b]?._listener?.onNodeDown(a);
  }

  void _send(_MemoryTransport from, String to, Uint8List frame) {
    final target = _nodes[to];
    final pair = _pair(from.localNode, to);
    final direction = (from.localNode, to);
    // A cut connection passes nothing until its loss is reported.
    if (_broken.contains(pair) || _failing.contains(direction)) return;
    if (target == null || target._closed || _cut.contains(pair)) {
      // Unreachable. A connection that was thought to be up is torn down by
      // the partition's own timer; a fresh attempt fails by itself, and
      // until the sender is told, nothing more goes that way.
      if (!_connected.contains(pair) && _failing.add(direction)) {
        Timer(detectAfter, () {
          _failing.remove(direction);
          if (!from._closed) from._listener?.onNodeDown(to);
        });
      }
      return;
    }
    if (_connected.add(pair)) {
      from._listener?.onNodeUp(to);
      target._listener?.onNodeUp(from.localNode);
    }
    // One timer per frame, but each firing delivers the oldest frame in
    // flight: that keeps the order whatever the jitter and whatever order
    // timers due at the same instant fire in.
    final flight = from._flight.putIfAbsent(to, Queue.new)..add(frame);
    final extra = jitter == Duration.zero
        ? Duration.zero
        : Duration(microseconds: _random.nextInt(jitter.inMicroseconds + 1));
    Timer(latency + extra, () {
      if (flight.isEmpty || target._closed) return;
      target._listener?.onFrame(from.localNode, flight.removeFirst());
    });
  }

  void _leave(_MemoryTransport node) {
    for (final other in _nodes.keys.toList()) {
      if (other != node.localNode) _disconnect(node.localNode, other);
    }
    _nodes.remove(node.localNode);
  }
}

class _MemoryTransport implements Transport {
  final InMemoryNetwork _network;
  @override
  final String localNode;
  TransportListener? _listener;
  bool _closed = false;

  /// Frames on their way from here, by destination.
  final _flight = <String, Queue<Uint8List>>{};

  _MemoryTransport(this._network, this.localNode);

  @override
  void attach(TransportListener listener) => _listener = listener;

  @override
  void send(String node, Uint8List frame) {
    if (_closed) return;
    // The receiver must not see later changes to the sender's buffer.
    _network._send(this, node, Uint8List.fromList(frame));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _network._leave(this);
    _listener = null;
  }
}
