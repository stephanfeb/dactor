# dactor_libp2p

A libp2p transport for [`dactor_remote`](../dactor_remote/README.md). Experimental and not published.

Over this transport:

- A node is named by its libp2p peer id, so a remote reference looks like `dactor://12D3KooW…/bob?cap=…`.
- The security handshake (Noise) authenticates every peer. A frame that arrives from a node comes from the holder of that node's key.
- Everything is encrypted on the wire, capability tokens included.
- A node behind a NAT can be reached through a circuit relay.

```dart
import 'package:dactor_libp2p/dactor_libp2p.dart';

final transport = Libp2pTransport(await startHost(), closeHost: true);
final node = RemoteNode(system, transport, codecs: codecs());

// Before a first contact, libp2p needs an address for the other node:
await transport.addAddress('/ip4/203.0.113.7/udp/4001/udx/p2p/12D3KooW…');
final store = node.resolve('dactor://12D3KooW…/store?cap=…');
```

`example/two_nodes.dart` runs as two operating-system processes. The server prints its libp2p address and the store's dactor address, and the client takes both.

## Hosts

`Libp2pTransport` takes a started `Host` and adds one protocol, `/dactor/remote/1.0.0`, to it. You can build that host however your deployment needs, with `Libp2p.new_` as spiffyvault does. The transport closes the host only when given `closeHost: true`.

For the common case, `startHost` builds one with UDX, Noise and Yamux:

| Parameter | Meaning |
|---|---|
| `keyPair` | The node's identity, and so its name. Pass a stored one for a name that survives restarts. |
| `listen` | Multiaddresses to listen on. Empty for a node that is only reached through relays or connections it opens. |
| `relay`, `relays` | `RelayRole.none`, `client` (can dial relay addresses), `reserve` (reserves a slot on `relays` so others can reach it), `server` (relays for others). |
| `holePunching` | Try to upgrade a relayed connection to a direct one. |
| `observersNeeded` | How many peers must report the same public address before the node uses it (libp2p's default is 4). A punch needs that address; a node that only talks to its relay has one observer, so set 1 there. |
| `announce` | Which of its addresses the node advertises, replacing libp2p's default filter; for example, only relay addresses. |
| `keepAlive`, `keepAliveTimeout` | Yamux ping interval, and how long a ping may go unanswered before the connection is closed. |
| `allowLoopback` | Keep loopback addresses, for tests on one machine. |

## Reaching a node behind a NAT

1. The phone starts with `relay: RelayRole.reserve, relays: [relayAddress], listen: const []`.
2. After a few seconds (libp2p's AutoRelay start-up), `transport.addresses` holds a relay address: `<relay>/p2p-circuit/p2p/<phone>`.
3. Another node calls `addAddress` with that address and reaches the phone through the relay.
4. Replies and messages from the phone back to that node go over the same connection. The phone needs no address for it.

`test/relay_test.dart` does this with three hosts on loopback. The "phone" listens on nothing, so the relay is its only way in. It covers both directions and checks that every connection between the two goes through the relay. It also checks that both sides notice when the relay goes away.

### Through real NAT routers

`test/nat/run.sh` runs two dactor nodes in Docker, each behind its own NAT router. A Ricochet server is the relay: go-libp2p over UDX on a simulated public internet. It uses go-ricochet's mailbox Docker setup (`RICOCHET_DIR`, by default the `go-ricochet` checkout next to this repository) and layers `test/nat/compose.yml` over it. It has three checks:

- **check** (hole punching off): an ask through the relay, 5,000 messages in order, a 1 MiB message, and the listener asking back over the same connection. Every connection stays relayed.
- **punch**: a hole punch gives a direct connection about 0.5 s after the relayed one. Within another 0.4 s dactor's traffic has moved onto it, and an ask and 5,000 ordered messages follow with no node reported down.
- **watch**: the listener's container is killed. The dialer gets `NoConnectionExit` about 3.7 s later, with a 1 s keep-alive and a 3 s timeout.

With cone NATs (`NAT_TYPE=cone`, the default) all three pass. With `NAT_TYPE=symmetric` the punch fails, as it should, and the rest pass over the relay. `CHECKS=punch` runs one check; `LOG=p2p-holepunch` prints libp2p's loggers from both nodes.

No real phone or carrier NAT has been tried.

## Leaving the relay

When a direct connection to a node appears while frames to it go through a relay, the transport moves them onto the direct one. This happens after a hole punch, or when the node is dialled directly. The old stream ends with a marker (an empty frame) and a new stream continues on the direct connection. The receiver reads a node's newer stream only after the older one has ended with the marker, so frames keep their order, nothing is lost, and the node is not reported down. `routeTo(node)` gives the connection frames to a node currently use.

Without this, traffic stays on the relay as long as the stream lives. It would also be cut whenever a relay with limits ends the relayed connection; go-libp2p's default limits are 2 minutes or 128 KiB. `test/move_off_relay_test.dart` moves mid-stream, in both directions, during 5,000 ordered messages.

For a hole punch, both nodes need their public address. They learn it from the peers that observe them (see `observersNeeded`); without it the listener's punch stops with "No public address to send".

## When a node is lost

- **A broken stream or connection reports the node down.** Watchers and linked actors get `NoConnectionExit`, and pending asks fail with `NodeUnreachable`. The next message opens a new stream. Moving off a relay (above) is not a break.
- **A peer that vanishes without closing anything** (a killed process, a phone out of signal) is noticed through the Yamux keep-alive, after `keepAliveTimeout`. UDX's own 30 s idle timeout is the backstop. `test/keepalive_test.dart` kills a peer process and expects it noticed within 5 s with a 2 s timeout; it takes about 2.2 s.
- **A dial to a node that is gone fails only after `dialTimeout`**, 15 s by default. Over UDP nothing refuses a dial, so an `ask` with a shorter timeout fails with `TimeoutException` instead of `NodeUnreachable`.

## Same as local

`test/libp2p_transport_test.dart` runs the eleven tell/ask/watch/link scenarios of `dactor_remote`. These are the same ones run over the in-memory network and TCP. It also runs the transport scenarios: a lost node is noticed and a new one is reachable, 5,000 messages arrive in order, and a 2 MB message arrives whole. All pass.

## Cost

Measured on loopback with all nodes in one process (`tool/throughput.dart`):

| | One-way messages per second | Time per ask |
|---|---|---|
| Local | ~420k–620k | ~3.5–4.5 µs |
| TCP | ~100k–125k | ~57 µs |
| libp2p (UDX, Noise, Yamux) | ~78k–100k | ~880–900 µs |

Most of the ask latency belongs to the stack. A raw 8-byte round trip on one libp2p stream takes about 600–620 µs (`tool/rtt_probe.dart`).

## Known problems in dart_libp2p

- `AddrInfo.fromMultiaddr` takes the first `/p2p/` component of an address, which for a relay address is the relay. `Libp2pTransport.addAddress` parses addresses itself.
- Fixed in 4.12.1, which this package requires: a dial that did not reuse a listener's socket leaked its UDP socket, so a process could not exit after closing its hosts. `tool/exit_probe.dart` was the reproduction.

## Not here yet

- Discovery: no DHT or mDNS integration. Addresses are handed over by hand.
- Tests on real devices and a carrier NAT.
- Many streams per node pair (one per direction now, so a large message delays the ones behind it).
