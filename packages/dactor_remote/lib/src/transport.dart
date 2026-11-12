import 'dart:typed_data';

/// Carries frames between nodes. A `RemoteNode` sits on top of one.
///
/// What a transport promises:
///
/// - Frames between two nodes arrive in the order they were sent, or not at
///   all.
/// - [TransportListener.onNodeUp] is called before the first frame from a
///   node is delivered.
/// - [TransportListener.onNodeDown] is called when the connection to a node
///   is lost, and also when a [send] could not reach a node at all. Without
///   that second half, an actor watching something on an unreachable node
///   would wait for ever.
///
/// What it does not promise: delivery. A frame sent just before a connection
/// drops may be lost without notice.
abstract interface class Transport {
  /// This node's name on the network. Other nodes use it to address frames
  /// here, and it appears in every remote reference to an actor of this
  /// node.
  String get localNode;

  /// Starts delivering to [listener]. Called once, before any [send].
  void attach(TransportListener listener);

  /// Sends [frame] to [node], connecting first if necessary. Never throws
  /// for an unreachable node; see the class comment.
  void send(String node, Uint8List frame);

  Future<void> close();
}

/// The callbacks of a [Transport].
abstract interface class TransportListener {
  void onFrame(String from, Uint8List frame);
  void onNodeUp(String node);
  void onNodeDown(String node);
}

/// A [Transport] whose nodes are reached at addresses that can be passed
/// from node to node: the basis of discovery in dactor.
///
/// A `RemoteNode` on such a transport sends the addresses of a node along
/// with references to its actors (in messages, and in the text of
/// `uriOf`), and process groups pass on the addresses of the nodes they
/// know. So whoever hands out a reference also says how to reach it.
///
/// Addresses are opaque to everything but the transport. A wrong one costs
/// a failed dial, nothing more, as long as the transport authenticates
/// nodes (libp2p does: an address cannot make another key answer for a
/// node).
abstract interface class AddressBook {
  /// How other nodes can reach this one, best first. Empty while it does
  /// not know (before a relay reservation, for example).
  List<String> get localAddresses;

  /// What this node knows of how to reach [node]; empty when nothing.
  List<String> addressesOf(String node);

  /// Learned from elsewhere: [node] may be reached at [addresses]. The
  /// transport drops those it cannot use, and those for any other node.
  void learn(String node, List<String> addresses);
}
