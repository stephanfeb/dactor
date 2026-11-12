import 'dart:async';

import 'package:dactor/dactor.dart';

import 'process_groups.dart';
import 'remote_node.dart';

/// Sent to an actor that lost its global name to another one, after two
/// nodes registered the same name without seeing each other (concurrently,
/// or on both sides of a partition). The name is no longer registered for
/// the actor that receives this; [winner] holds it.
final class NameConflict {
  final String name;
  final ActorRef winner;
  const NameConflict(this.name, this.winner);

  @override
  String toString() => 'NameConflict($name, winner: ${winner.id})';
}

/// Names that refer to one actor across all nodes of a scope, after
/// Erlang's `global`.
///
/// Built on [ProcessGroups]: a name is a group, and a node registers a name
/// for one of its own actors by joining it. [register] refuses a name that
/// any node is known to hold. Two nodes can still register the same name
/// while they cannot see each other's registrations: within the time it
/// takes a registration to reach the other nodes, or during a partition.
/// When they do see each other, every node picks the same winner (the
/// holder on the node whose name sorts first), and the loser's node
/// unregisters it and sends the losing actor a [NameConflict]. So names
/// are unique once the network is quiet, not at every moment. Erlang's
/// `global` takes a cluster-wide lock to register, which narrows the first
/// window but not the second.
///
/// A name is released when its actor ends.
class GlobalNames {
  final RemoteNode node;
  final ProcessGroups _groups;
  late final StreamSubscription<GroupChange> _changes;

  GlobalNames(this.node,
      {String scope = 'default',
      Duration retry = const Duration(seconds: 5),
      bool Function(String node)? accept})
      : _groups = ProcessGroups(node,
            scope: '\$global/$scope', retry: retry, accept: accept) {
    _changes = _groups.changes.listen((change) => _resolve(change.group));
  }

  /// Adds [peer] to the scope; see [ProcessGroups.connect].
  void connect(String peer) => _groups.connect(peer);

  /// The other nodes of the scope this node knows of.
  Set<String> get nodes => _groups.nodes;

  /// Registers [name] for the local actor [actor]. Returns false if any
  /// node is known to hold the name already.
  bool register(String name, ActorRef actor) {
    if (_groups.members(name).isNotEmpty) return false;
    _groups.join(name, actor);
    return true;
  }

  /// Releases [name], if this node holds it.
  void unregister(String name) {
    for (final actor in _groups.localMembers(name)) {
      _groups.leave(name, actor);
    }
  }

  /// The actor registered as [name], or null.
  ActorRef? whereis(String name) => _winner(_groups.members(name));

  /// Every name registered, as far as this node knows.
  Set<String> get names => _groups.groups;

  Future<void> close() async {
    unawaited(_changes.cancel());
    await _groups.close();
  }

  ActorRef? _winner(List<ActorRef> holders) {
    if (holders.isEmpty) return null;
    String nodeOf(ActorRef ref) => ref is RemoteRef ? ref.node : node.id;
    return holders.reduce((a, b) {
      final order = nodeOf(a).compareTo(nodeOf(b));
      return order < 0 || (order == 0 && a.id.compareTo(b.id) <= 0) ? a : b;
    });
  }

  void _resolve(String name) {
    final holders = _groups.members(name);
    if (holders.length < 2) return;
    final winner = _winner(holders)!;
    // Each node gives up only its own losers; the others do the same.
    for (final loser in _groups.localMembers(name)) {
      if (loser == winner) continue;
      _groups.leave(name, loser);
      loser.tell(NameConflict(name, winner));
    }
  }
}
