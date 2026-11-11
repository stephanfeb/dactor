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

`test/same_as_local_test.dart` runs eleven scenarios three ways: both actors in one system, on two nodes of the in-memory network, and on two nodes over TCP. They cover tell and reply, ask from outside and inside a handler, ask to a dead actor, watch (normal stop, failure, already dead), and link (failure with a supervised partner, trapped exit, normal stop, already dead, unlink). The observed behaviour is the same in all three, apart from these differences:

| | Local | Remote |
|---|---|---|
| Messages | Passed by reference | Encoded. Plain values (null, bool, int, double, String, `Uint8List`, lists and maps of those) need nothing; every other type needs a codec, and `tell` throws `UnregisteredMessageType` without one. Records are not plain values. |
| Delivery | Certain while the actor lives | Not guaranteed. A message in flight when a connection drops is lost. Order between two nodes is kept. |
| Errors in exit reasons and failed calls | The error object | A `RemoteActorError` carrying its text |
| A lost connection | Cannot happen | Watchers get `Terminated`, linked actors an exit signal, both with `NoConnectionExit`; pending asks fail with `NodeUnreachable`. The remote actor may be alive. |
| `isAlive` | Whether the actor is alive | Whether this node is open. Watch the actor to learn of its end. |
| Reaching an actor | Anyone with its id | Only with a reference that carries a capability token |

A watch or link is over once it has fired. After a partition heals, the same references work again; watch or link again if you still care.

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

A libp2p transport, which would give authenticated peers, encryption and NAT traversal, is not written yet.

## Remote spawn

```dart
// On the node that will host the actor:
node.registerBehaviour('counter', (args) => Counter(args as int));

// On another node:
final counter = await node.spawnOn('<node>', 'counter', 'c1', args: 40);
```

Closures cannot travel, so the behaviour is named and its arguments encoded. Registering a behaviour is the permission: any node that can connect can spawn it.

## Cost

Loopback TCP, both nodes in one process (`tool/throughput.dart`): about 89k one-way messages per second against about 630k locally, and about 70 µs per ask against 4 µs.

## Not here yet

A libp2p transport; node heartbeats (a silent, still-open connection is not detected); cluster membership; a registry of names or process groups across nodes; end-to-end encryption; generated codecs; `unwatch`.
