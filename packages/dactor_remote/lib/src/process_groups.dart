import 'dart:async';

import 'package:dactor/dactor.dart';

import 'remote_node.dart';

/// A change to a group, as seen from this node.
final class GroupChange {
  final String group;
  final List<ActorRef> joined;
  final List<ActorRef> left;
  const GroupChange(this.group, {this.joined = const [], this.left = const []});

  @override
  String toString() => 'GroupChange($group, joined: ${joined.length}, '
      'left: ${left.length})';
}

/// Named groups of actors across nodes, after Erlang's `pg`.
///
/// Any actor can be in any number of groups, and a group can have members
/// on any number of nodes. [members] gives every member this node knows of.
///
/// How it stays consistent: a node is the only one that changes its own
/// actors' memberships. When it meets another node of the same [scope] it
/// sends all of them, and after that every join and leave; frames between
/// two nodes keep their order. When the connection to a node is lost, its
/// members are dropped here, and when it is back, it sends them all again.
/// So once the network is quiet, every node of the scope sees the same
/// members, without any conflict to resolve.
///
/// - A member that ends leaves all its groups.
/// - Nodes of the scope tell each other which other nodes they know, and
///   connect to those too, so that the scope becomes a full mesh. On a
///   transport that is an [AddressBook] (libp2p), they also pass on the
///   addresses they know for those nodes, so a node needs an address for
///   one node of the scope only.
/// - Nodes that are known but not connected are retried every [retry].
///   One that another node passed on is forgotten once it has not been
///   reached for [forgetAfter], and is no longer passed on once a retry
///   has missed it: a node that is gone for good leaves the scope instead
///   of being retried, and spread, for ever. Nodes given to [connect] are
///   retried for as long as this runs.
/// - Members are passed with their capability tokens: joining a group lets
///   every node of the scope send to that actor. Use [accept] to choose
///   which nodes may take part.
///
/// [members] reflects only what has reached this node; during a partition
/// each side sees its own members.
class ProcessGroups {
  final RemoteNode node;
  final String scope;

  /// How often nodes that are known but not connected are tried again.
  final Duration retry;

  /// How long a node that another node passed on can stay unreachable
  /// before this node forgets it. Counted in retries, so time this node
  /// spends suspended (an app in the background) does not count.
  final Duration forgetAfter;

  /// Which nodes may take part. Others are ignored.
  final bool Function(String node) accept;

  final _local = <String, Set<ActorRef>>{};
  final _remote = <String, Map<String, Set<ActorRef>>>{};
  final _known = <String>{};
  final _synced = <String>{};
  // Given to [connect]: never forgotten.
  final _pinned = <String>{};
  // Retries in a row that found a known node unreached.
  final _misses = <String, int>{};
  // Not synchronous: a listener may join or leave in response, which adds
  // an event of its own.
  final _changes = StreamController<GroupChange>.broadcast();
  late final _Watcher _watcher = _Watcher(this);
  late final StreamSubscription<NodeEvent> _events;
  Timer? _timer;
  bool _closed = false;

  ProcessGroups(this.node,
      {this.scope = 'default',
      this.retry = const Duration(seconds: 5),
      this.forgetAfter = const Duration(minutes: 10),
      bool Function(String node)? accept})
      : accept = accept ?? _anyNode {
    node.serve(_service, _onFrame);
    _events = node.events.listen((event) {
      switch (event) {
        case NodeUp(node: final peer):
          if (_known.contains(peer) && !_synced.contains(peer)) _sync(peer);
        case NodeDown(node: final peer):
          _lost(peer);
      }
    });
    _timer = Timer.periodic(retry, (_) => _retry());
  }

  static bool _anyNode(String node) => true;

  String get _service => '\$pg/$scope';

  /// Changes to groups as this node sees them: local joins and leaves,
  /// and those reported by other nodes or implied by losing them.
  Stream<GroupChange> get changes => _changes.stream;

  /// The other nodes of the scope this node knows of.
  Set<String> get nodes => Set.unmodifiable(_known);

  /// Adds [peer] to the scope: this node and [peer] exchange their
  /// memberships, and keep doing so.
  void connect(String peer) {
    if (_closed || peer == node.id || !accept(peer)) return;
    _known.add(peer);
    _pinned.add(peer);
    if (!_synced.contains(peer)) _sync(peer);
  }

  /// Adds the local actor [actor] to [group]. Joining twice is joining
  /// once.
  void join(String group, ActorRef actor) {
    _checkLocal(actor);
    if (!(_local[group] ??= {}).add(actor)) return;
    if (!_isMember(actor, except: group)) actor.watch(_watcher);
    _broadcast(['join', group], [actor]);
    _changes.add(GroupChange(group, joined: [actor]));
  }

  /// Removes the local actor [actor] from [group].
  void leave(String group, ActorRef actor) {
    final members = _local[group];
    if (members == null || !members.remove(actor)) return;
    if (members.isEmpty) _local.remove(group);
    if (!_isMember(actor)) actor.unwatch(_watcher);
    _broadcast(['leave', group], [actor]);
    _changes.add(GroupChange(group, left: [actor]));
  }

  /// Every member of [group] this node knows of, local ones first.
  List<ActorRef> members(String group) => [
        ...?_local[group],
        for (final groups in _remote.values) ...?groups[group],
      ];

  /// The members of [group] on this node.
  List<ActorRef> localMembers(String group) => [...?_local[group]];

  /// Every group with a member this node knows of.
  Set<String> get groups => {
        ..._local.keys,
        for (final groups in _remote.values) ...groups.keys,
      };

  /// Stops taking part. Other nodes keep this node's members until they
  /// lose the connection to it.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    // Not awaited: cancelling a subscription to a synchronous stream
    // returns a future of the root zone, which a simulation never runs.
    unawaited(_events.cancel());
    node.stopServing(_service);
    for (final actor in {for (final m in _local.values) ...m}) {
      actor.unwatch(_watcher);
    }
    await _changes.close();
  }

  // ---- inside ----

  void _checkLocal(ActorRef actor) {
    if (actor is RemoteRef ||
        !identical(node.system.getActor(actor.id), actor)) {
      throw ArgumentError.value(
          actor.id, 'actor', 'is not an actor of this node');
    }
  }

  bool _isMember(ActorRef actor, {String? except}) =>
      _local.entries.any((e) => e.key != except && e.value.contains(actor));

  /// Sends this node's memberships and the nodes it knows to [peer].
  void _sync(String peer) {
    if (_closed) return;
    _synced.add(peer);
    final groups = _local.entries.toList();
    node.sendToService(peer, _service, [
      'sync',
      [
        for (final e in groups) [e.key, e.value.length]
      ],
      // The other nodes this one knows, with how to reach them, so that
      // the scope becomes a mesh even where a node had no address for the
      // others.
      // Not those a retry has missed: a node gone for good would spread.
      [
        for (final n in _known)
          if (n != peer && !_misses.containsKey(n))
            [n, node.addressesOf(n).take(RemoteNode.maxAddresses).toList()]
      ],
      // Whether this node lacks [peer]'s memberships and needs them sent
      // back, even if [peer] thinks it sent them already: one side can
      // notice a lost connection that the other did not.
      !_remote.containsKey(peer),
    ], refs: [
      for (final e in groups) ...e.value
    ]);
  }

  void _broadcast(List<Object?> data, List<ActorRef> refs) {
    for (final peer in _synced) {
      node.sendToService(peer, _service, data, refs: refs);
    }
  }

  void _onFrame(String from, Object? data, List<ActorRef> refs) {
    if (_closed || !accept(from)) return;
    // A node speaks only for its own actors.
    final own = [
      for (final ref in refs)
        if (ref is RemoteRef && ref.node == from) ref
    ];
    if (own.length != refs.length) return;
    switch (data) {
      case ['sync', List groups, List others, bool wantsReply]:
        _known.add(from);
        _misses.remove(from);
        final fresh = <String, Set<ActorRef>>{};
        var at = 0;
        for (final [String group, int count] in groups.cast<List>()) {
          if (count <= 0) continue;
          fresh[group] = own.sublist(at, at + count).toSet();
          at += count;
        }
        _replace(from, fresh);
        if (wantsReply || !_synced.contains(from)) _sync(from);
        for (final entry in others) {
          if (entry case [String other, List addresses]
              when other != node.id && accept(other)) {
            node.learnAddresses(other, addresses);
            if (_known.add(other)) _sync(other);
          }
        }
      case ['join', String group]:
        // Only after a sync from that node; until then it is not a member
        // of the scope as far as this node knows.
        final groups = _remote[from];
        if (groups == null) return;
        final added =
            own.where((ref) => (groups[group] ??= {}).add(ref)).toList();
        if (added.isNotEmpty) {
          _changes.add(GroupChange(group, joined: added));
        }
      case ['leave', String group]:
        final members = _remote[from]?[group];
        if (members == null) return;
        final removed = own.where(members.remove).toList();
        if (members.isEmpty) _remote[from]!.remove(group);
        if (removed.isNotEmpty) {
          _changes.add(GroupChange(group, left: removed));
        }
    }
  }

  /// Replaces what [peer] has in each group, reporting the difference.
  void _replace(String peer, Map<String, Set<ActorRef>> fresh) {
    final old = _remote[peer] ?? const <String, Set<ActorRef>>{};
    _remote[peer] = fresh;
    for (final group in {...old.keys, ...fresh.keys}) {
      final before = old[group] ?? const <ActorRef>{};
      final after = fresh[group] ?? const <ActorRef>{};
      final joined = after.difference(before).toList();
      final left = before.difference(after).toList();
      if (joined.isNotEmpty || left.isNotEmpty) {
        _changes.add(GroupChange(group, joined: joined, left: left));
      }
    }
  }

  /// Tries again the known nodes that are not connected, and forgets
  /// those that were passed on and have been unreachable too long.
  void _retry() {
    final limit = forgetAfter.inMicroseconds / retry.inMicroseconds;
    for (final peer in _known.toList()) {
      if (_remote.containsKey(peer)) continue;
      final misses = _misses[peer] = (_misses[peer] ?? 0) + 1;
      if (!_pinned.contains(peer) && misses >= limit) {
        _known.remove(peer);
        _misses.remove(peer);
        continue;
      }
      if (!_synced.contains(peer)) _sync(peer);
    }
  }

  void _lost(String peer) {
    _synced.remove(peer);
    final groups = _remote.remove(peer);
    if (groups == null || _closed) return;
    for (final MapEntry(key: group, value: members) in groups.entries) {
      if (members.isNotEmpty) {
        _changes.add(GroupChange(group, left: members.toList()));
      }
    }
  }

  void _ended(ActorRef actor) {
    for (final group in [
      for (final e in _local.entries)
        if (e.value.contains(actor)) e.key
    ]) {
      leave(group, actor);
    }
  }
}

/// Told when a local member ends.
class _Watcher implements ActorRef {
  final ProcessGroups _groups;
  _Watcher(this._groups);

  @override
  String get id => '\$pg/${_groups.scope}';

  @override
  bool get isAlive => !_groups._closed;

  @override
  void tell(Object? message) {
    final payload = message;
    if (payload is Terminated && !_groups._closed) {
      _groups._ended(payload.actor);
    }
  }

  @override
  Future<T> ask<T>(Object? message, [Duration? timeout]) =>
      throw UnsupportedError('Not an actor');

  @override
  void watch(ActorRef watcher) => throw UnsupportedError('Not an actor');

  @override
  void unwatch(ActorRef watcher) {}
}
