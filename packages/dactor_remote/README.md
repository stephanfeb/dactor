# dactor_remote

Location-transparent actor references for [dactor](../..). An actor on another node is an ordinary `ActorRef`: `tell`, `ask`, `watch` and `context.link` work on it, and when it arrives as the sender of a message, replying works too.

Experimental. Part of the OTP gap work on the `experimental/otp-gap` branch; not published.

## Two nodes

```dart
// Node B: serve an actor.
final node = RemoteNode(system, transport, codecs: codecs());
node.expose('store', await system.spawn('store', () => KeyValueStore()));

// Node A: find it and use it.
final node = RemoteNode(system, transport, codecs: codecs());
final store = (await node.lookup('<node B>', 'store')).typed<KvMsg>();
store.tell(Put('language', 'Dart'));
print(await store.call(Fetch('language')));
```

`example/two_nodes.dart` is the same thing as two operating-system processes.

## What is the same as local, and what is not

`test/same_as_local_test.dart` runs eleven scenarios three ways: both actors in one system, on two nodes of the in-memory network, and on two nodes over TCP. `dactor_libp2p` runs the same ones (they live in `test/support/transport_scenarios.dart`) over libp2p. They cover tell and reply, ask from outside and inside a handler, ask to a dead actor, watch (normal stop, failure, already dead), and link (failure with a supervised partner, trapped exit, normal stop, already dead, unlink). The observed behaviour is the same in all three, apart from these differences:

| | Local | Remote |
|---|---|---|
| Messages | Passed by reference | Encoded. Plain values (null, bool, int, double, String, `Uint8List`, lists and maps of those) need nothing; every other type needs a codec, and `tell` throws `UnregisteredMessageType` without one. Records are not plain values. |
| Delivery | Certain while the actor lives | Not guaranteed. A message in flight when a connection drops is lost. Order between two nodes is kept. |
| Errors in exit reasons and failed calls | The error object | A `RemoteActorError` carrying its text |
| A lost connection | Cannot happen | Watchers get `Terminated`, linked actors an exit signal, both with `NoConnectionExit`; pending asks fail with `NodeUnreachable`. The remote actor may be alive. |
| `isAlive` | Whether the actor is alive | Whether this node is open. Watch the actor to learn of its end. |
| Reaching an actor | Anyone with its id | Only with a reference that carries a capability token |

`unwatch` works across nodes. When a node is lost, the watches it had placed on this node's actors are dropped. A watch or link is over once it has fired. After a partition heals, the same references work again; watch or link again if you still care.

## Codecs

```dart
final codecs = CodecRegistry()
  ..register<OrderPlaced>('OrderPlaced',
      encode: (m, ctx) => [m.orderId, m.amount, ctx.encodeRef(m.replyTo)],
      decode: (data, ctx) {
        final [id as String, amount as double, replyTo] = data as List;
        return OrderPlaced(id, amount, ctx.decodeRef(replyTo));
      });
```

A codec turns a message into a tree of plain values and back. `ctx.encodeRef` and `ctx.decodeRef` carry actor references inside messages; `ctx.encodeValue` and `ctx.decodeValue` nest other registered types. Types are matched by exact class. To change a type's shape, register the new shape under a higher `version` and keep the old one readable with `registerDecoder`.

Frames are CBOR maps with integer keys, encoded by a small built-in CBOR implementation that is tested against the RFC 8949 examples and against truncated, oversized and random input.

## Capabilities

A node accepts a frame for an actor only if it carries that actor's token: the first 16 bytes of an HMAC-SHA256 of the actor's id under the node's secret. Without the token the frame is dropped and counted (`remote.frames.unauthorized`), and the sender is told the same thing it would be told about an actor that does not exist.

- A peer gets its first reference by name, from `expose` and `lookup`, or as text from `uriOf` and `resolve`.
- After that, references spread only by being sent, inside messages or as senders.
- A token opens one actor. It is a bearer token: whoever is handed it can use it and pass it on, and it cannot be taken back short of changing the node's secret.
- Replies, death notices and exit signals are accepted only from the node that was asked, watched or linked.
- By default the secret is random per process, so references die with it. Pass `secret:` to keep them valid across restarts.
- `requireCapabilities: false` turns all of this off.

Tokens are only as secret as the transport keeps them.

## Transports

A `Transport` carries frames between named nodes and reports connections made and lost.

| | |
|---|---|
| `InMemoryNetwork` | Nodes in one isolate, with latency, jitter, `partition`, `heal` and `isolate`. Runs on timers, so inside `simulate` and `explore` from `package:dactor/simulation.dart` the whole network is on virtual time and replays from the seed. `Simulation.addSystem()` gives each node its own actor system. |
| `TcpTransport` (`package:dactor_remote/tcp.dart`) | Plain TCP. **No authentication, no encryption.** For one machine, a fully trusted network, and tests. |

`Libp2pTransport`, in the separate package [`dactor_libp2p`](../dactor_libp2p/README.md), gives authenticated peers, encryption, relays and NAT traversal. It is a package of its own so that this one does not depend on libp2p.

## Remote spawn

```dart
// On the node that will host the actor:
node.registerBehaviour('counter', (args) => Counter(args as int));

// On another node:
final counter = await node.spawnOn('<node>', 'counter', 'c1', args: 40);
```

Closures cannot travel, so the behaviour is named and its arguments encoded. Registering a behaviour is the permission: any node that can connect can spawn it.

## Process groups

```dart
final groups = ProcessGroups(node);   // one per node and scope
groups.connect('<other node>');       // the rest of the scope is found through it
groups.join('workers', worker);       // a local actor
final all = groups.members('workers'); // local and remote, as refs
groups.changes.listen((c) => ...);     // GroupChange(group, joined:, left:)
```

After Erlang's `pg`. Each node is the only one that changes its own members; it tells the others when it joins or leaves, and sends all of them to a node it meets. A member that ends leaves by itself. When a node is lost, its members disappear from the others' view, and come back when it is reachable again (retried every `retry`). Nodes pass on the nodes they know, so connecting to one node of a scope is enough. A node accepts only members that are actors of the node that sends them; `accept:` keeps other nodes out of the scope. A group is eventually consistent: during a partition, each side sees its own side.

## Global names

```dart
final names = GlobalNames(node);
names.connect('<other node>');
if (names.register('leader', me)) { ... }
final leader = names.whereis('leader');
```

After Erlang's `global`, built on process groups: a name is a group with one member. `register` refuses a name any node is known to hold. Two nodes can still take the same name while they cannot see each other (within a message's travel time, or across a partition). When they meet, every node picks the same winner, the holder on the node whose name sorts first; the loser's node unregisters it and sends the losing actor a `NameConflict`. Names are unique once the network is quiet, not at every moment. A name is released when its actor ends.

`test/simulated_groups_test.dart` runs 300 seeded histories each of joins, leaves, deaths, registrations, partitions and heals on four nodes, and checks that every node ends up agreeing with the truth.

## Services

`node.serve(name, handler)` and `node.sendToService(node, name, data, refs:)` exchange messages between nodes rather than actors. The handler learns which node sent each message, as the transport authenticated it. Groups and names are built on this, because the sender of an actor message is not authenticated.

## Cost

Loopback TCP, both nodes in one process (`tool/throughput.dart`): about 89k one-way messages per second against about 630k locally, and about 70 µs per ask against 4 µs.

## Not here yet

Node heartbeats in this package (a silent, still-open connection is not detected over TCP; over libp2p the muxer's keep-alive detects it); cluster membership beyond the nodes of a group scope; end-to-end encryption; generated codecs.
