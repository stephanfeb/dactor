import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dactor/dactor.dart';

import 'cbor.dart';
import 'codec.dart';
import 'transport.dart';

/// Thrown by `ask` on a remote reference when the connection to its node is
/// lost, or cannot be made, before the reply arrives.
class NodeUnreachable implements Exception {
  final String node;
  const NodeUnreachable(this.node);

  @override
  String toString() => 'NodeUnreachable: lost the connection to $node';
}

/// A change in the connection to another node.
sealed class NodeEvent {
  final String node;
  const NodeEvent(this.node);
}

final class NodeUp extends NodeEvent {
  const NodeUp(super.node);
  @override
  String toString() => 'NodeUp($node)';
}

final class NodeDown extends NodeEvent {
  const NodeDown(super.node);
  @override
  String toString() => 'NodeDown($node)';
}

// Frame kinds.
const _kMessage = 0;
const _kReply = 1;
const _kWatch = 2;
const _kTerminated = 4;
const _kLink = 5;
const _kUnlink = 6;
const _kExit = 7;
const _kLookup = 8;
const _kSpawn = 9;

// Frame fields. Small integers keep the frames small.
const _fKind = 0;
const _fType = 1;
const _fVersion = 2;
const _fPath = 3;
const _fSender = 4;
const _fCorrelation = 5;
const _fPayload = 9;
const _fCapability = 10;
const _fError = 11;
const _fOther = 12;
const _fReason = 13;
const _fOtherCapability = 14;
const _fName = 15;
const _fId = 16;

/// Connects an actor system to other nodes.
///
/// ```dart
/// final node = RemoteNode(system, transport);
/// node.expose('orders', ordersRef);
///
/// // On another node:
/// final orders = await node.lookup('server-1', 'orders');
/// orders.tell(LocalMessage(payload: 'hello'));
/// ```
///
/// A reference to an actor on another node is an ordinary [ActorRef]:
/// `tell`, `ask`, `watch` and `context.link` work on it, and when it arrives
/// as the sender of a message, replying to it works too.
///
/// **What differs from a local reference**
///
/// - Messages are encoded. Plain values travel as they are; any other type
///   needs a codec in [codecs], and `tell` throws
///   [UnregisteredMessageType] without one.
/// - Delivery is not guaranteed. A message in flight when a connection
///   drops is lost.
/// - When the connection to a node is lost, watchers of its actors receive
///   `Terminated` and linked actors an exit signal, both with
///   `NoConnectionExit`, and pending asks fail with [NodeUnreachable]. The
///   remote actor may be alive; this node cannot tell. A watch or link is
///   over once it has fired, as always; make a new one after reconnecting.
///
/// **Capabilities**
///
/// A node only accepts messages for an actor from a peer that holds a
/// reference to it. References carry a token that only this node can
/// produce (an HMAC of the actor's id under this node's secret), and a
/// frame without the right token is dropped. A peer gets its first
/// reference by name, from [expose] and [lookup]; after that, references
/// spread only by being sent in messages or as senders. Tokens are bearer
/// tokens: whoever is handed one can use it and pass it on. They are only
/// as secret as the transport keeps them.
class RemoteNode implements TransportListener {
  final LocalActorSystem system;
  final Transport transport;
  final CodecRegistry codecs;

  /// How long `ask`, [lookup] and [spawnOn] wait when given no timeout.
  final Duration defaultTimeout;

  /// When false, tokens are neither checked nor required: any peer can
  /// address any actor by id. For closed networks and tests.
  final bool requireCapabilities;

  final Hmac _hmac;
  final Zone _zone = Zone.current;
  late final _Context _context = _Context(this);
  final _events = StreamController<NodeEvent>.broadcast(sync: true);

  final _up = <String>{};
  int _nextCorrelation = 0;
  final _pending = <int, _Pending>{};

  /// Local watchers of remote actors: (node, path) to watchers.
  final _watching = <(String, String), Set<ActorRef>>{};

  /// Links between a local actor and a remote one: (node, local id, remote
  /// path).
  final _links = <(String, String, String)>{};

  final _exposed = <String, ActorRef>{};
  final _behaviours = <String, Actor Function(Object? args)>{};

  /// Local references without an id in the system (the temporary senders
  /// of `ask`), by the path other nodes know them under.
  final _temporary = <String, ActorRef>{};
  final _temporaryPaths = Expando<String>();
  int _nextTemporary = 0;
  bool _closed = false;

  /// [secret] keys this node's capability tokens. Give the same secret to a
  /// node that restarts if references handed out before should stay valid;
  /// by default a random one is made, and old references die with the
  /// process.
  RemoteNode(
    this.system,
    this.transport, {
    CodecRegistry? codecs,
    List<int>? secret,
    this.defaultTimeout = const Duration(seconds: 5),
    this.requireCapabilities = true,
  })  : codecs = codecs ?? CodecRegistry(),
        _hmac = Hmac(sha256, secret ?? _randomSecret()) {
    transport.attach(this);
  }

  static List<int> _randomSecret() {
    final random = Random.secure();
    return List<int>.generate(32, (_) => random.nextInt(256));
  }

  /// This node's name, as other nodes address it.
  String get id => transport.localNode;

  /// Connections made and lost.
  Stream<NodeEvent> get events => _events.stream;

  /// Whether a connection to [node] is currently up.
  bool isConnected(String node) => _up.contains(node);

  /// Makes [actor] findable by other nodes under [name].
  void expose(String name, ActorRef actor) => _exposed[name] = actor;

  void unexpose(String name) => _exposed.remove(name);

  /// A reference to the actor that [node] exposes as [name].
  ///
  /// Fails with a [StateError] if the node exposes nothing by that name,
  /// with [NodeUnreachable] if it cannot be reached, and with a
  /// [TimeoutException] if it does not answer.
  Future<ActorRef> lookup(String node, String name, {Duration? timeout}) =>
      _request<ActorRef>(node, {_fKind: _kLookup, _fName: name}, timeout);

  /// Lets other nodes start actors of this kind here with [spawnOn].
  /// Registering a behaviour is the permission: any node that can connect
  /// can spawn it.
  void registerBehaviour(String name, Actor Function(Object? args) factory) =>
      _behaviours[name] = factory;

  /// Starts an actor on [node] from the behaviour registered there as
  /// [behaviour], with the id [id], and returns a reference to it. [args]
  /// must be encodable; the factory on the other side receives it decoded.
  Future<ActorRef> spawnOn(String node, String behaviour, String id,
      {Object? args, Duration? timeout}) {
    final (type, version, data) = codecs.encode(args, _context);
    return _request<ActorRef>(
        node,
        {
          _fKind: _kSpawn,
          _fName: behaviour,
          _fId: id,
          _fType: type,
          _fVersion: version,
          _fPayload: data,
        },
        timeout);
  }

  /// The address of [actor] as text: `dactor://<node>/<id>`, with the
  /// capability token as a `cap` query parameter. Anyone who has the text
  /// has the reference.
  String uriOf(ActorRef actor) {
    final [node as String, path as String, cap] =
        _context.encodeRef(actor) as List;
    final address = 'dactor://${Uri.encodeComponent(node)}/'
        '${Uri.encodeComponent(path)}';
    return cap == null ? address : '$address?cap=${_hex(cap as Uint8List)}';
  }

  /// The reference behind a result of [uriOf].
  ActorRef resolve(String uri) {
    const scheme = 'dactor://';
    final query = uri.indexOf('?');
    final address = query < 0 ? uri : uri.substring(0, query);
    final slash = address.indexOf('/', scheme.length);
    if (!uri.startsWith(scheme) || slash < 0 || slash == address.length - 1) {
      throw FormatException('Not a dactor address', uri);
    }
    final parameters = query < 0
        ? const <String, String>{}
        : Uri.splitQueryString(uri.substring(query + 1));
    final cap = parameters['cap'];
    return _context.decodeRef([
      Uri.decodeComponent(address.substring(scheme.length, slash)),
      Uri.decodeComponent(address.substring(slash + 1)),
      cap == null ? null : _unhex(cap),
    ]);
  }

  /// Disconnects from every node and stops accepting frames. Pending asks
  /// fail, and watchers and linked actors are told `NoConnectionExit`.
  Future<void> close() async {
    if (_closed) return;
    for (final node in _up.toList()) {
      onNodeDown(node);
    }
    _closed = true;
    await transport.close();
    await _events.close();
  }

  // ---- capabilities ----

  Uint8List _capabilityFor(String path) =>
      Uint8List.fromList(_hmac.convert(utf8.encode(path)).bytes.sublist(0, 16));

  bool _allowed(String path, Object? capability) {
    if (!requireCapabilities) return true;
    if (capability is! Uint8List || capability.length != 16) return false;
    final expected = _capabilityFor(path);
    var difference = 0;
    for (var i = 0; i < 16; i++) {
      difference |= expected[i] ^ capability[i];
    }
    return difference == 0;
  }

  // ---- local references on the wire ----

  String _pathOf(ActorRef local) {
    if (identical(system.getActor(local.id), local)) return local.id;
    final known = _temporaryPaths[local];
    if (known != null) return known;
    if (_temporary.length >= 256) {
      _temporary.removeWhere((_, ref) => !ref.isAlive);
    }
    final path = '\$temp/${_nextTemporary++}';
    _temporary[path] = local;
    _temporaryPaths[local] = path;
    return path;
  }

  ActorRef? _localActor(String path) =>
      path.startsWith('\$temp/') ? _temporary[path] : system.getActor(path);

  // ---- sending ----

  void _send(String node, Map<int, Object?> frame) {
    if (_closed) return;
    final bytes = cborEncode(frame);
    // In the node's zone, not the caller's: an actor that sends and then
    // dies takes the timers and callbacks of its own zone with it, and the
    // frame must not be among them.
    _zone.run(() => transport.send(node, bytes));
  }

  void _tell(RemoteRef target, Object? payload, ActorRef? sender,
      {int? correlation}) {
    final (type, version, data) = codecs.encode(payload, _context);
    _send(target.node, {
      _fKind: _kMessage,
      _fPath: target.path,
      _fCapability: target._capability,
      _fType: type,
      _fVersion: version,
      _fPayload: data,
      if (sender != null) _fSender: _context.encodeRef(sender),
      if (correlation != null) _fCorrelation: correlation,
    });
  }

  Future<T> _ask<T>(RemoteRef target, Object? payload, Duration? timeout) {
    final pending =
        _expect<T>(target.node, timeout, 'Ask to ${target.id} timed out');
    try {
      _tell(target, payload, null, correlation: pending.correlation);
    } catch (_) {
      _pending.remove(pending.correlation)?.timer.cancel();
      rethrow;
    }
    return pending.completer.future;
  }

  Future<T> _request<T>(
      String node, Map<int, Object?> frame, Duration? timeout) {
    final pending = _expect<T>(node, timeout, 'Request to $node timed out');
    _send(node, {...frame, _fCorrelation: pending.correlation});
    return pending.completer.future;
  }

  /// Registers a reply to wait for. The completer belongs to the caller's
  /// zone, so the caller hears about errors; the timer belongs to the
  /// node's, so it outlives an actor that asked and died.
  _Pending<T> _expect<T>(String node, Duration? timeout, String what) {
    if (_closed) throw StateError('This node is closed');
    final correlation = _nextCorrelation++;
    final completer = Completer<T>();
    final limit = timeout ?? defaultTimeout;
    final timer = _zone.run(() => Timer(limit, () {
          if (_pending.remove(correlation) != null) {
            completer.completeError(
                TimeoutException(what, limit), StackTrace.current);
          }
        }));
    return _pending[correlation] =
        _Pending<T>(correlation, node, completer, timer);
  }

  void _watch(RemoteRef target, ActorRef watcher) {
    final watchers =
        _watching.putIfAbsent((target.node, target.path), () => {});
    if (!watchers.add(watcher)) return;
    if (watchers.length > 1) return;
    _send(target.node, {
      _fKind: _kWatch,
      _fPath: target.path,
      _fCapability: target._capability,
    });
  }

  void _linkFrom(RemoteRef target, ActorRef local) {
    _links.add((target.node, local.id, target.path));
    _send(target.node, {
      _fKind: _kLink,
      _fPath: target.path,
      _fCapability: target._capability,
      _fOther: local.id,
      _fOtherCapability: _capabilityFor(local.id),
    });
  }

  void _unlinkFrom(RemoteRef target, ActorRef local) {
    if (!_links.remove((target.node, local.id, target.path))) return;
    _send(target.node,
        {_fKind: _kUnlink, _fPath: target.path, _fOther: local.id});
  }

  void _linkedExit(RemoteRef target, ActorRef local, ExitReason reason) {
    if (!_links.remove((target.node, local.id, target.path))) return;
    _send(target.node, {
      _fKind: _kExit,
      _fPath: target.path,
      _fOther: local.id,
      _fReason: _encodeReason(reason),
    });
  }

  // ---- receiving ----

  @override
  void onNodeUp(String node) => _zone.runGuarded(() {
        if (_closed || !_up.add(node)) return;
        _events.add(NodeUp(node));
      });

  @override
  void onNodeDown(String node) => _zone.runGuarded(() {
        if (_closed) return;
        _up.remove(node);

        for (final pending
            in _pending.values.where((p) => p.node == node).toList()) {
          _pending.remove(pending.correlation);
          pending.timer.cancel();
          pending.fail(NodeUnreachable(node));
        }

        for (final key in _watching.keys.where((k) => k.$1 == node).toList()) {
          final ref = RemoteRef._(this, node, key.$2, null);
          for (final watcher in _watching.remove(key)!) {
            watcher.tell(LocalMessage(
                payload: Terminated(ref, reason: const NoConnectionExit())));
          }
        }

        for (final link in _links.where((l) => l.$1 == node).toList()) {
          _links.remove(link);
          final local = system.getActor(link.$2);
          if (local != null) {
            system.foreignExit(local, RemoteRef._(this, node, link.$3, null),
                const NoConnectionExit());
          }
        }
        _events.add(NodeDown(node));
      });

  @override
  void onFrame(String from, Uint8List bytes) => _zone.runGuarded(() {
        if (_closed) return;
        try {
          final frame = cborDecode(bytes);
          if (frame is! Map) throw const FormatException('Not a frame');
          _handle(from, frame);
        } catch (error) {
          // Whatever a peer sends, it must not be able to break this node.
          system.metrics.increment('remote.frames.rejected');
          system.logger.record(LogRecord(
              LogLevel.warning, 'Rejected a frame from $from: $error'));
        }
      });

  void _handle(String from, Map<Object?, Object?> frame) {
    switch (frame[_fKind]) {
      case _kMessage:
        _onMessage(from, frame);
      case _kReply:
        _onReply(from, frame);
      case _kWatch:
        _onWatch(from, frame);
      case _kTerminated:
        _onTerminated(from, frame);
      case _kLink:
        _onLink(from, frame);
      case _kUnlink:
        final local = system.getActor(frame[_fPath] as String);
        final other = frame[_fOther] as String;
        if (local != null && _links.remove((from, local.id, other))) {
          system.unlinkForeign(local, RemoteRef._(this, from, other, null));
        }
      case _kExit:
        final local = system.getActor(frame[_fPath] as String);
        final other = frame[_fOther] as String;
        // Only an actor that really is linked can be signalled.
        if (local != null && _links.remove((from, local.id, other))) {
          system.foreignExit(local, RemoteRef._(this, from, other, null),
              _decodeReason(frame[_fReason]));
        }
      case _kLookup:
        _onLookup(from, frame);
      case _kSpawn:
        _onSpawn(from, frame);
      default:
        throw FormatException('Unknown frame kind ${frame[_fKind]}');
    }
  }

  /// The target of a frame, or null (after refusing it) if the sender may
  /// not address it or it is gone.
  ActorRef? _target(String from, Map<Object?, Object?> frame,
      {required bool deadLetter}) {
    final path = frame[_fPath] as String;
    if (!_allowed(path, frame[_fCapability])) {
      system.metrics.increment('remote.frames.unauthorized');
      system.logger.record(LogRecord(LogLevel.warning,
          'Refused a frame from $from for $path: no valid capability'));
      return null;
    }
    final target = _localActor(path);
    if (target == null || !target.isAlive) {
      if (deadLetter) system.metrics.increment('remote.dead_letters');
      return null;
    }
    return target;
  }

  void _onMessage(String from, Map<Object?, Object?> frame) {
    final correlation = frame[_fCorrelation] as int?;
    final target = _target(from, frame, deadLetter: true);
    if (target == null) {
      if (correlation != null) {
        _send(from, {
          _fKind: _kReply,
          _fCorrelation: correlation,
          _fError: 'Actor ${frame[_fPath]} is not alive',
        });
      }
      return;
    }
    final payload = codecs.decode(frame[_fType] as String,
        frame[_fVersion] as int, frame[_fPayload], _context);
    final ActorRef? sender = correlation != null
        ? _ReplyRef(this, from, correlation)
        : frame[_fSender] == null
            ? null
            : _context.decodeRef(frame[_fSender]);
    target.tell(LocalMessage(payload: payload), sender: sender);
  }

  void _onReply(String from, Map<Object?, Object?> frame) {
    final pending = _pending[frame[_fCorrelation]];
    // A reply counts only from the node that was asked.
    if (pending == null || pending.node != from) return;
    _pending.remove(pending.correlation);
    pending.timer.cancel();
    final error = frame[_fError];
    if (error != null) {
      pending.fail(StateError(error as String));
      return;
    }
    try {
      pending.succeed(codecs.decode(frame[_fType] as String,
          frame[_fVersion] as int, frame[_fPayload], _context));
    } catch (e) {
      pending.fail(e);
    }
  }

  void _onWatch(String from, Map<Object?, Object?> frame) {
    final path = frame[_fPath] as String;
    final target = _target(from, frame, deadLetter: false);
    if (target == null) {
      _send(from, {
        _fKind: _kTerminated,
        _fPath: path,
        _fReason: _encodeReason(const NoProcExit()),
      });
      return;
    }
    target.watch(_WatchRelay(this, from, path));
  }

  void _onTerminated(String from, Map<Object?, Object?> frame) {
    final path = frame[_fPath] as String;
    // Only what is being watched can be reported dead.
    final watchers = _watching.remove((from, path));
    if (watchers == null) return;
    final terminated = Terminated(RemoteRef._(this, from, path, null),
        reason: _decodeReason(frame[_fReason]));
    for (final watcher in watchers) {
      watcher.tell(LocalMessage(payload: terminated));
    }
  }

  void _onLink(String from, Map<Object?, Object?> frame) {
    final path = frame[_fPath] as String;
    final other = frame[_fOther] as String;
    final foreign =
        RemoteRef._(this, from, other, frame[_fOtherCapability] as Uint8List?);
    final target = _target(from, frame, deadLetter: false);
    if (target == null || !system.linkForeign(target, foreign)) {
      _send(from, {
        _fKind: _kExit,
        _fPath: other,
        _fOther: path,
        _fReason: _encodeReason(const NoProcExit()),
      });
      return;
    }
    _links.add((from, path, other));
  }

  void _onLookup(String from, Map<Object?, Object?> frame) {
    final correlation = frame[_fCorrelation] as int;
    final name = frame[_fName] as String;
    final actor = _exposed[name];
    if (actor == null || !actor.isAlive) {
      _send(from, {
        _fKind: _kReply,
        _fCorrelation: correlation,
        _fError: 'Node $id exposes no actor called "$name"',
      });
      return;
    }
    _reply(from, correlation, actor);
  }

  void _onSpawn(String from, Map<Object?, Object?> frame) {
    final correlation = frame[_fCorrelation] as int;
    final name = frame[_fName] as String;
    final factory = _behaviours[name];
    void refuse(Object error) => _send(from, {
          _fKind: _kReply,
          _fCorrelation: correlation,
          _fError: '$error',
        });
    if (factory == null) {
      refuse('Node $id has no behaviour called "$name"');
      return;
    }
    final args = codecs.decode(frame[_fType] as String, frame[_fVersion] as int,
        frame[_fPayload], _context);
    system.spawn(frame[_fId] as String, () => factory(args)).then(
        (ref) => _reply(from, correlation, ref),
        onError: (Object e) => refuse(e));
  }

  void _reply(String node, int correlation, Object? value) {
    final Map<int, Object?> frame;
    try {
      final (type, version, data) = codecs.encode(value, _context);
      frame = {
        _fKind: _kReply,
        _fCorrelation: correlation,
        _fType: type,
        _fVersion: version,
        _fPayload: data,
      };
    } catch (e) {
      // Let the asker fail now instead of at its timeout.
      _send(node, {_fKind: _kReply, _fCorrelation: correlation, _fError: '$e'});
      rethrow;
    }
    _send(node, frame);
  }
}

class _Pending<T> {
  final int correlation;
  final String node;
  final Completer<T> completer;
  final Timer timer;
  _Pending(this.correlation, this.node, this.completer, this.timer);

  void succeed(Object? value) {
    if (value is T) {
      completer.complete(value);
    } else {
      completer.completeError(
          StateError('Reply type mismatch. Expected: $T, '
              'but received: ${value.runtimeType}'),
          StackTrace.current);
    }
  }

  void fail(Object error) => completer.completeError(error, StackTrace.current);
}

class _Context implements CodecContext {
  final RemoteNode node;
  _Context(this.node);

  @override
  Object? encodeRef(ActorRef ref) {
    if (ref is RemoteRef) return [ref.node, ref.path, ref._capability];
    if (ref is _ReplyRef) {
      throw ArgumentError(
          'The sender of a remote ask can be replied to, not passed on');
    }
    final path = node._pathOf(ref);
    return [node.id, path, node._capabilityFor(path)];
  }

  @override
  ActorRef decodeRef(Object? data) {
    final [name as String, path as String, capability as Uint8List?] =
        data as List;
    if (name == node.id) {
      // One of this node's own, coming home.
      if (!node._allowed(path, capability)) {
        throw StateError('A reference to $path came back without a valid '
            'capability');
      }
      return node._localActor(path) ?? _Gone(path);
    }
    return RemoteRef._(node, name, path, capability);
  }

  @override
  Object? encodeValue(Object? value) {
    final (type, version, data) = node.codecs.encode(value, this);
    return type.isEmpty ? [data] : [type, version, data];
  }

  @override
  Object? decodeValue(Object? data) => switch (data) {
        [final plain] => plain,
        [String type, int version, final inner] =>
          node.codecs.decode(type, version, inner, this),
        _ => throw const FormatException('Not an encoded value'),
      };
}

/// A reference to an actor on another node.
///
/// Two remote references are equal when they name the same actor on the
/// same node.
final class RemoteRef implements ForeignActorRef {
  final RemoteNode _node;

  /// The node the actor lives on.
  final String node;

  /// The actor's id on that node.
  final String path;

  final Uint8List? _capability;

  RemoteRef._(this._node, this.node, this.path, this._capability);

  @override
  String get id => 'dactor://$node/$path';

  /// Whether the connection to the actor's node is not known to be down.
  /// It says nothing certain about the actor itself; watch it for that.
  @override
  bool get isAlive => !_node._closed;

  @override
  void tell(Message message, {ActorRef? sender}) {
    final local = message is LocalMessage ? message : null;
    _node._tell(
        this, local == null ? message : local.payload, sender ?? local?.sender);
  }

  @override
  Future<T> ask<T>(Message message, [Duration? timeout]) => _node._ask<T>(
      this, message is LocalMessage ? message.payload : message, timeout);

  @override
  void watch(ActorRef watcher) => _node._watch(this, watcher);

  @override
  void linkFrom(ActorRef local) => _node._linkFrom(this, local);

  @override
  void unlinkFrom(ActorRef local) => _node._unlinkFrom(this, local);

  @override
  void linkedExit(ActorRef local, ExitReason reason) =>
      _node._linkedExit(this, local, reason);

  @override
  bool operator ==(Object other) =>
      other is RemoteRef && other.node == node && other.path == path;

  @override
  int get hashCode => Object.hash(node, path);

  @override
  String toString() => id;
}

/// The sender of a remote ask, as the asked actor sees it. Replying to it
/// answers the ask.
class _ReplyRef implements ActorRef {
  final RemoteNode _node;
  final String _to;
  final int _correlation;
  bool _used = false;
  _ReplyRef(this._node, this._to, this._correlation);

  @override
  String get id => 'dactor://$_to/\$ask/$_correlation';

  @override
  bool get isAlive => !_used && !_node._closed;

  @override
  void tell(Message message, {ActorRef? sender}) {
    if (_used) return;
    _used = true;
    _node._reply(
        _to, _correlation, message is LocalMessage ? message.payload : message);
  }

  @override
  Future<T> ask<T>(Message message, [Duration? timeout]) =>
      throw UnsupportedError('Cannot ask the sender of an ask');

  @override
  void watch(ActorRef watcher) =>
      throw UnsupportedError('Cannot watch the sender of an ask');
}

/// Registered as a watcher of a local actor on behalf of another node.
class _WatchRelay implements ActorRef {
  final RemoteNode _node;
  final String _to;
  final String _watched;
  _WatchRelay(this._node, this._to, this._watched);

  @override
  String get id => 'dactor://$_to/\$watch/$_watched';

  @override
  bool get isAlive => !_node._closed;

  @override
  void tell(Message message, {ActorRef? sender}) {
    final payload = message is LocalMessage ? message.payload : message;
    if (payload is! Terminated) return;
    _node._send(_to, {
      _fKind: _kTerminated,
      _fPath: _watched,
      _fReason: _encodeReason(payload.reason),
    });
  }

  @override
  Future<T> ask<T>(Message message, [Duration? timeout]) =>
      throw UnsupportedError('Not an actor');

  @override
  void watch(ActorRef watcher) => throw UnsupportedError('Not an actor');
}

/// A local reference that came back from the wire after its actor ended.
class _Gone implements ActorRef {
  @override
  final String id;
  _Gone(this.id);

  @override
  bool get isAlive => false;

  @override
  void tell(Message message, {ActorRef? sender}) {}

  @override
  Future<T> ask<T>(Message message, [Duration? timeout]) =>
      Future.error(StateError('Actor $id is not alive'));

  @override
  void watch(ActorRef watcher) => watcher.tell(
      LocalMessage(payload: Terminated(this, reason: const NoProcExit())));
}

Object? _encodeReason(ExitReason reason) => switch (reason) {
      NormalExit() => [0],
      ShutdownExit() => [1],
      KilledExit() => [2],
      ErrorExit(:final error) => [3, '$error'],
      NoProcExit() => [4],
      NoConnectionExit() => [5],
    };

ExitReason _decodeReason(Object? data) => switch (data) {
      [0] => const NormalExit(),
      [1] => const ShutdownExit(),
      [2] => const KilledExit(),
      [3, String text] => ErrorExit(RemoteActorError(text), StackTrace.empty),
      [4] => const NoProcExit(),
      [5] => const NoConnectionExit(),
      _ => throw const FormatException('Not an exit reason'),
    };

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List _unhex(String text) {
  if (text.length.isOdd) throw const FormatException('Odd-length hex');
  return Uint8List.fromList([
    for (var i = 0; i < text.length; i += 2)
      int.parse(text.substring(i, i + 2), radix: 16)
  ]);
}
