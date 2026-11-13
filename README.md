# Dactor - Actor System for Dart

**A lightweight, high-performance actor model implementation for Dart**

Dactor provides a robust actor system for building concurrent, fault-tolerant, and scalable applications in Dart. It implements the actor model with features like supervision trees, message passing, ask patterns with reliability, metrics, and pooling.

[![Pub Version](https://img.shields.io/pub/v/dactor)](https://pub.dev/packages/dactor)
[![Dart SDK](https://img.shields.io/badge/dart-%3E%3D3.5.1-blue)](https://dart.dev)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

## ✨ Features

- 🎯 **Pure Actor Model**: Type-safe message passing with actor isolation
- 🔄 **Ask Pattern**: request-response with timeouts, and opt-in retries with exponential backoff
- 🛡️ **Fault Tolerance**: OTP-style supervisors, links, monitors and exit reasons; each actor runs in its own zone
- 🧪 **Deterministic Simulation**: seeded scheduling, virtual time and fault injection; a failing seed replays exactly
- 🧱 **Isolate Placement**: run any actor in its own isolate, with a watchdog that kills and restarts it if it hangs
- 🧩 **Typed Behaviours**: `GenServer`, `GenStatem` and `TypedRef<M>` with compile-time checked messages
- 📡 **Event Bus**: Publish-subscribe messaging for event-driven architectures
- ⏰ **Actor Timers**: Schedule messages with single-shot, fixed-delay, and fixed-rate timers
- ⚡ **High Performance**: about 500K messages/sec to one actor, tens of microseconds per message
- 📊 **Built-in Observability**: Comprehensive metrics, tracing, and monitoring
- 🎛️ **Actor Pooling**: Scale with worker pools and round-robin routing
- 💾 **Memory Efficient**: about 1.7 KB per idle actor
- 🔍 **Dead Letter Queue**: Handle undeliverable messages gracefully
- 🚀 **Pure Dart**: no platform channels or native code; the only runtime dependencies are `uuid` and `meta`

## 🚀 Quick Start

Add to your `pubspec.yaml`:

```yaml
dependencies:
  dactor: ^2.0.0
```

### Basic Example

A counter, written as a `GenServer`: the state is a value, the messages are a sealed class, and the compiler checks both.

```dart
import 'package:dactor/dactor.dart';
import 'package:dactor/spi.dart';

// The messages the counter accepts. A message that mixes in Call<R> expects
// a reply of type R.
sealed class CounterMsg {}

final class Increment extends CounterMsg {}

final class Get extends CounterMsg with Call<int> {}

// A server whose state is an int and whose messages are CounterMsg.
class Counter extends GenServer<int, CounterMsg> {
  @override
  int init() => 0;

  // Messages that expect no reply: return the new state.
  @override
  int handleCast(CounterMsg message, int state) => switch (message) {
        Increment() => state + 1,
        Get() => state,
      };

  // Requests: reply and return the new state.
  @override
  CallResult<int> handleCall(CounterMsg request, int state, From from) =>
      switch (request) {
        Get() => request.reply(state, state),
        Increment() => NoReply(state),
      };

  @override
  void terminate(int state) => print('Counter stopped at $state');
}

void main() async {
  final system = LocalActorSystem();

  // typed() restricts the reference to the counter's messages.
  final TypedRef<CounterMsg> counter =
      (await system.spawn('counter', () => Counter())).typed();

  counter.tell(Increment());
  counter.tell(Increment());
  // counter.tell('increment');  // does not compile

  final int count = await counter.call(Get());
  print('Current count: $count');

  await system.shutdown();
}
```

The same file is in `example/gen_server_example.dart`. A `GenServer` is an ordinary actor underneath. You can also extend `Actor` directly and handle whatever arrives in `onMessage(dynamic message)`; the rest of this document mostly does, and the two styles mix freely in one system.

## 📚 Core Concepts

### Actor Lifecycle

Actors have a well-defined lifecycle managed by the system:

```dart
class MyActor extends Actor {
  @override
  void preStart() {
    // Called when actor starts
    print('Actor ${context.self.id} starting');
  }

  @override
  Future<void> onMessage(dynamic message) async {
    // Handle incoming messages
    print('Received: $message');
  }

  @override
  void postStop() {
    // Called when actor stops (cleanup)
    print('Actor ${context.self.id} stopped');
  }
}
```

### Message Passing

Any value can be a message. `tell` sends it as it is, and the actor's `onMessage` receives exactly that value:

```dart
counter.tell('increment');
counter.tell(Deposit(100));
```

#### Senders are stamped, not passed

`tell` takes no sender. The runtime records the actor whose code is calling `tell`, or none if the call comes from outside any actor. The receiver sees it as `context.sender`, and answering is `context.sender?.tell(reply)`. An actor cannot claim to be another one.

An actor that hands work on, such as a router, uses `context.forward(target, message)`. That keeps the original sender, so `target` answers whoever asked.

`Terminated` and `ExitSignal` come only from the runtime. One told in the ordinary way is dropped to the dead letters.

Code that is not an actor but carries messages for one, such as a transport or a bridge, can name a sender with `sendAs` from `package:dactor/spi.dart`:

```dart
import 'package:dactor/spi.dart';

sendAs(replyTo, () => actor.tell('request'));
```

In tests, `probe.send(actor, message)` from `dactor_test` does the same with a probe as the sender.

`LocalMessage`, `AskableMessage` and `AskableResponse` are deprecated and will be removed in 3.0. A `LocalMessage` that is told is unwrapped to its payload, and the sender it carries is ignored.

## 🎯 Ask Pattern with Reliability

The ask pattern provides reliable request-response messaging with configurable retries:

### Basic Ask Pattern

```dart
// Simple ask with timeout
final response = await actor.ask('ping', Duration(seconds: 1));

// With custom message
final result = await actor.ask(
  'get_data',
  Duration(seconds: 5),
);
```

### Configurable Reliability

```dart
// Development configuration (longer timeouts, more retries)
final system = ActorSystem.create(ActorSystemConfig(
  askConfig: AskConfig.development(),
));

// Production configuration (shorter timeouts, fewer retries)
final system = ActorSystem.create(ActorSystemConfig(
  askConfig: AskConfig.production(),
));

// Custom configuration
final system = ActorSystem.create(ActorSystemConfig(
  askConfig: AskConfig(
    defaultTimeout: Duration(seconds: 3),
    maxRetries: 2,
    retryBackoffBase: Duration(milliseconds: 100),
    retryBackoffMultiplier: 2.0,
    maxBackoffDuration: Duration(seconds: 5),
  ),
));

// Disable retries entirely
final system = ActorSystem.create(ActorSystemConfig(
  askConfig: AskConfig.noRetries(),
));
```

### Exponential Backoff

The system automatically calculates backoff delays:

```dart
final config = AskConfig(
  retryBackoffBase: Duration(milliseconds: 100),
  retryBackoffMultiplier: 2.0,
);

// Retry attempts will wait:
// 1st retry: 100ms
// 2nd retry: 200ms  
// 3rd retry: 400ms
// 4th retry: 800ms (and so on...)
```

## 🛡️ Supervision and Fault Tolerance

A supervisor starts children, and decides what happens when one fails:

```dart
class WorkerActor extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {
    if (message == 'fail') {
      throw Exception('Simulated failure');
    }
    // Handle other messages...
  }
}

class MySupervisor extends SupervisorActor {
  MySupervisor()
      : super(const OneForOneStrategy(
          decider: _decide,
          maxRestarts: 3,
          period: Duration(seconds: 5),
        ));

  static SupervisionDecision _decide(Object error, StackTrace stackTrace) =>
      SupervisionDecision.restart;

  // Children created in preStart come back when the supervisor is restarted.
  @override
  Future<void> preStart() => startChildren([
        ChildSpec('worker', () => WorkerActor()),
        ChildSpec('cache', () => CacheActor(), restart: RestartType.transient),
      ]);
}

final supervisor = await system.spawn('supervisor', () => MySupervisor());
final worker = system.getActor('supervisor/worker');
```

### Supervision Strategies

A strategy says which children a restart applies to:

| Strategy | Restarts |
|---|---|
| `OneForOneStrategy` | Only the child that failed |
| `AllForOneStrategy` | Every child of the supervisor |
| `RestForOneStrategy` | The failed child and every child started after it |

Strategies hold no state, so one instance can be shared between supervisors.

### Restart Budget

`maxRestarts` and `period` set how much restarting a supervisor tolerates, **across all of its children together**. The defaults are 10 restarts in 5 seconds.

When the budget is exceeded the supervisor gives up: it fails with `RestartLimitExceeded`, its children are stopped with it, and its own supervisor decides what to do, typically restarting the whole subtree from a clean state. A crash loop therefore climbs the tree until some level can fix it, or stops at the top.

A top-level actor spawned with `supervision:` has a budget of its own and is stopped when it runs out.

### Child Specs

```dart
ChildSpec('worker', () => WorkerActor(),
    restart: RestartType.permanent,          // the default
    shutdown: Duration(seconds: 2));         // wait this long when stopping it
```

| `RestartType` | The child is started again |
|---|---|
| `permanent` | After a failure, and also if it stops for any other reason the supervisor did not ask for |
| `transient` | After a failure or a kill, but not after a normal stop |
| `temporary` | Never; a temporary child that fails is stopped and forgotten |

- A failed child is restarted in place and keeps its `ActorRef`. A child that had *stopped* is gone, so it is started again as a new actor under the same id: look it up again with `getActor`.
- `supervisor.terminateChild(name)` stops a child for good, whatever its restart type.
- `supervise(name, factory)` is shorthand for `startChild(ChildSpec(name, factory))`.

Supervision decisions run as messages in the supervisor's own mailbox, ahead of its ordinary messages. A decision never overlaps the supervisor's `onMessage`, and the failed child receives nothing until the decision is made.

**Supervision Decisions**:
- `SupervisionDecision.restart` - Restart the failed actor in place. The `ActorRef`, its mailbox (pending messages are kept), watchers and event-bus subscriptions survive; only the `Actor` instance is replaced. `postStop` runs on the old instance and `preStart` on the new one. The message that caused the failure is not redelivered.
- `SupervisionDecision.stop` - Stop the failed actor permanently
- `SupervisionDecision.resume` - Keep the actor and its state; the failing message is dropped
- `SupervisionDecision.escalate` - Pass the failure up: the supervisor is treated as having failed with the same error and its own parent decides. Escalating past a top-level actor stops it.

**Tree semantics**:
- Stopping an actor stops its children first, last started first.
- Restarting an actor also stops its children. Create children in `preStart` if they should come back with the supervisor.
- A top-level actor is governed by the `supervision:` strategy passed to `spawn`. Without one, it is stopped on its first failure.
- If `preStart` throws, `spawn` fails and the actor is not registered.

### Actor Isolation, Stop and Kill

Each actor runs in its own zone. Two things follow.

**Errors nothing caught belong to the actor.** A future the actor did not await, or a timer or stream callback it set up, can throw long after the handler returned. That error is treated as the actor failing, and goes to its supervisor like any other failure. It does not reach your application's top-level error handler.

**Nothing outlives the actor.** When an actor stops or restarts, everything the old instance left pending is dropped: timers are cancelled, and code suspended on an `await` never resumes.

```dart
await system.stop(ref);  // graceful
system.kill(ref);        // immediate
```

- `stop` delivers no further messages, waits for the handler in flight to finish (up to `ActorSystemConfig.stopTimeout`, 5 seconds by default), stops the children, then runs `postStop`. If the handler does not finish in time, the actor is killed.
- `kill` does not wait. Children are killed too, and `postStop` still runs.
- A killed handler is cut off at the `await` it is suspended on. **`finally` blocks around that `await` do not run**, so release sockets, files and subscriptions in `postStop`.
- An actor that stops itself (`context.system.stop(context.self)`) is cut off at that call: code after it does not run.

### Links and Exit Reasons

`watch` tells you that an actor ended. A link ties two actors' fates together.

```dart
class Session extends Actor {
  final ActorRef connection;
  Session(this.connection);

  @override
  void preStart() => context.link(connection);
  // If the connection actor fails, this session fails too,
  // and its supervisor restarts or stops it.
}
```

- A link works in both directions. If either actor ends abnormally, the other fails with `LinkedActorExited` and its supervisor decides what to do. Without a supervisor it stops.
- A normal exit (`system.stop`) does not propagate.
- An actor that sets `context.trapExits = true` in `preStart` is not brought down. It receives an `ExitSignal(from, reason)` message instead, for normal exits too.
- A restart ends the old incarnation, so linked actors are signalled and the link is gone. Link in `preStart` if the pairing should survive restarts.
- Linking to an actor that is already dead signals `NoProcExit` straight away.
- `context.unwatch(actor)` ends a watch and drops a `Terminated` from that actor still waiting in the mailbox, so none arrives after it (Erlang's `demonitor` with `flush`). `actor.unwatch(watcher)` on the ref removes the watch but not a notice already queued.

Both `ExitSignal` and `Terminated` carry an `ExitReason`:

| Reason | Meaning |
|---|---|
| `NormalExit` | Stopped on request |
| `ShutdownExit` | Stopped by its parent, or the system shut down |
| `KilledExit` | `kill`, or it did not stop within the stop timeout |
| `ErrorExit(error, stackTrace)` | It failed |
| `NoProcExit` | It did not exist |

```dart
switch (message) {
  case Terminated(:final actor, reason: ErrorExit(:final error)):
    print('${actor.id} crashed: $error');
  case Terminated(:final actor):
    print('${actor.id} is gone');
}
```

### Lints

Actors in one isolate share a heap, so nothing stops a message from carrying mutable state across. The `dactor_lints` analyzer plugin (in `packages/dactor_lints`, Dart 3.10 or later) reports the two common ways that happens:

- `dactor_mutable_message`: an object sent between actors has a field that can be reassigned.
- `dactor_captured_actor_state`: an actor sends a closure, or itself, in a message.

Limits: a handler in a synchronous loop cannot be interrupted, and work an actor starts through `Zone.root.run` is outside its zone.

## 🧩 Behaviours and Typed Messages

### Typed references

`ref.typed<M>()` gives a `TypedRef<M>`: the same reference, restricted at compile time to messages of type `M`. It costs nothing at run time, and `typedRef.untyped` gives the plain `ActorRef` back. A message class that mixes in `Call<R>` is a request, and `typedRef.call(request)` returns a `Future<R>`.

`call` fails with `TimeoutException` if no reply comes, with `CallException` if the handler threw, and with `StateError` if the actor is dead. It does not retry.

The type is a promise made where the reference is created. Nothing checks that the actor behind it understands `M`.

### GenServer

`GenServer<S, M>` holds a state of type `S` and accepts messages of type `M`.

| Override | Called for | Returns |
|----------|------------|---------|
| `init()` | start, in `preStart` | the first state |
| `handleCall(request, state, from)` | an `M` that mixes in `Call` | `request.reply(value, newState)`, `NoReply(newState)` or `StopReply(value, newState)` |
| `handleCast(message, state)` | any other `M` | the new state |
| `handleInfo(message, state)` | anything that is not an `M`, such as `Terminated` or `ExitSignal` | the new state |
| `handleContinue(arg, state)` | each `continueWith(arg)` from `init` or a handler, before the next message | the new state |
| `terminate(state)` | `postStop` | |
| `codeChange(oldVersion, oldState)` | start after `sys.upgrade` | the first state |

All of them may be asynchronous except `terminate`. `request.reply` checks the type of the reply against the request. After `NoReply`, answer later with `request.replyTo(from, value)`. A handler that throws changes nothing: the state is whatever the last handler returned. Work that should not hold up a caller goes in `handleContinue`: from `init` it runs after `spawn` has returned, from `handleCall` after the reply has gone, and in both cases before any other message, as OTP's `handle_continue` does.

### GenStatem

`GenStatem<S, D, M>` is a state machine with a state `S`, data `D` and events `M`. `onEvent(state, event, data)` answers every event with a transition:

| Transition | Effect |
|------------|--------|
| `next(state, data:, reply:, timeout:, eventTimeout:, timeouts:)` | Move to another state. Runs `onEnter`, cancels the old state timeout, replays postponed events. |
| `keep(data:, reply:, timeout:, eventTimeout:, timeouts:)` | Stay. |
| `postpone()` | Stay, and handle this event again after the next change of state. |
| `halt(reply:)` | Stop the machine. |

`reply:` answers a request that mixes in `Call<R>`. Give it as `request.answer(value)`, which checks that the value is an `R`.

There are three kinds of timeout, as in OTP:

| Timeout | Set with | Cancelled by | Calls |
|---------|----------|--------------|-------|
| State | `timeout:`, or `stateTimeout(state)` as a default | a change of state | `onTimeout(state, data)` |
| Event | `eventTimeout:` | any message at all | `onEventTimeout(state, data)` |
| Generic | `timeouts: {name: duration}` | setting the name to `null`, or `halt` | `onGenericTimeout(name, state, data)` |

Generic timeouts survive changes of state, and setting a name again restarts its timer. Messages that are not an `M` go to `onInfo`.

`example/gen_statem_example.dart` is a code lock that uses a state timeout and a postponed event.

### Selective receive

Inside a handler, `await context.receive<T>(where: ..., timeout: ...)` waits for one particular message and leaves the others in the mailbox, in order:

```dart
case StartTransfer(:final id):
  bank.tell(Debit(id));
  final ack = await context.receive<DebitAck>(
      where: (a) => a.id == id, timeout: Duration(seconds: 5));
```

The actor handles nothing else while it waits, and every call scans the mailbox. Use it for short request-and-acknowledge exchanges, not as the normal way to receive.

### Inspecting and changing running actors

`system.sys` (on `LocalActorSystem`) works on any running actor:

```dart
final sys = system.sys;
await sys.getState(ref);                  // a behaviour's state, or the Actor object
await sys.replaceState(ref, (s) => 0);    // behaviours only
sys.suspend(ref);                         // user messages queue up
sys.resume(ref);
sys.trace(ref, true);                     // log every message received, at debug level
sys.statistics(ref);                      // processed, mailbox size, restarts, suspended, busy
await sys.upgrade(ref, () => CounterV2()); // new code, same ref, mailbox and state
```

`getState` and `replaceState` are delivered through the actor's mailbox ahead of user messages, so they run between handlers and are answered even while the actor is suspended.

`upgrade` restarts the actor from the new factory. If the old and the new actor are both behaviours, the new one starts from `codeChange(oldVersion, oldState)` instead of `init()`; raise `version` when the shape of the state changes. Children are stopped as in any restart.

### Applications

An `Application` is a named supervision tree with dependencies. `ApplicationController` starts dependencies first, starts each application once, and stops in reverse order:

```dart
class Database extends Application {
  @override
  String get name => 'database';

  @override
  Future<ActorRef> start(ActorSystem system) =>
      system.spawn('database', () => DatabaseSupervisor());
}

class Web extends Application {
  @override
  String get name => 'web';

  @override
  List<Application> get dependencies => [Database()];

  @override
  Future<ActorRef> start(ActorSystem system) =>
      system.spawn('web', () => WebSupervisor());
}

final apps = ApplicationController(system);
await apps.start(Web());      // starts database, then web
await apps.stop('database');  // stops web, then database
await apps.stopAll();
```

When a root actor ends by itself, for instance because its supervisor gave up, the controller stops the applications that depend on it and calls `stopped()`. What happens next depends on the application's `restart` type, as in OTP:

| `restart` | When its root ends |
|-----------|--------------------|
| `temporary` (default) | Only this application and its dependents stop. |
| `transient` | Everything stops if the root ended abnormally. |
| `permanent` | Everything stops. |

Each of these is reported on `apps.exits` as an `ApplicationExit`. Dactor does not stop the Dart process; listen to `exits` to do that.

If an application fails to start, the ones that call had started are stopped again.

## 🧱 Actors in Their Own Isolate

Wrap an actor's factory in `Isolated` and it runs in an isolate of its own:

```dart
final checker = await system.spawn(
    'checker', () => Isolated(PrimeChecker.new),
    supervision: OneForOneStrategy(decider: (e, s) => SupervisionDecision.restart));
```

`Isolated` is an ordinary actor in your system that forwards each message to the real actor in the isolate and waits for it to be handled. So `tell`, `ask`, supervision, child specs, links, watches and pools all work as they do for any actor. `example/isolated_example.dart` shows one being killed in an infinite loop and restarted while the rest of the system carries on.

What the isolate gives you:

- **A separate heap.** Messages are copied across; nothing can be shared by accident.
- **A separate thread.** Long computations do not hold up other actors. For a pool of CPU-bound workers, combine it with `pool: Pool(workerCount: n)`.
- **A kill that always works.** A watchdog pings the isolate (`heartbeat`, 1 s by default). If it stays silent for `unresponsiveAfter` (5 s by default) it is killed, the actor fails with `IsolateUnresponsive`, and its supervisor decides what happens next. A restart starts a fresh isolate. Raise `unresponsiveAfter` for actors that legitimately compute for longer than that without an `await`.

What changes for the actor inside:

- `context.system` is a small system inside the isolate. Actors it spawns live and die there with it.
- `context.sender` points back to the sender in your system. It supports `tell` and `ask`, not `watch`.
- Messages must be sendable between isolates. One that is not goes to the dead letters with a logged warning. An `ActorRef` of your system is deliberately not sendable; only the sender of a message travels with it.
- The factory is sent to the isolate, so it must not capture anything unsendable. `Isolated(MyActor.new)` or a top-level function is always safe.
- A handler error is reported to the supervisor in your system. `resume` keeps the isolate and its state; `restart` and `stop` end it.

Cost, measured on one machine (Apple silicon, Dart 3.11): an isolate takes 35 to 135 µs to start and 11 to 32 KB of memory. A message to an isolated actor costs a round trip, so one-way throughput is about 60k msg/s against about 600k for a shared actor, and an `ask` takes about 20 µs against 3 µs. Use it for actors that compute, block, or run code you do not trust to return, not for everything.

Limits: an isolate blocked inside a native call (synchronous I/O, FFI, `sleep`) is killed only when that call returns. `Isolated` actors cannot run inside a simulation.

## 🌐 Actors on Other Nodes

`packages/dactor_remote` (experimental, not published) makes an actor on another node an ordinary `ActorRef`: `tell`, `ask`, `watch` and `context.link` work across nodes, a lost connection is reported as `NoConnectionExit`, and a node only accepts messages from peers that hold a reference to the actor. It comes with an in-memory network that runs under the simulator and a plain TCP transport for one machine. See its [README](packages/dactor_remote/README.md). `packages/dactor_libp2p` adds a libp2p transport: authenticated, encrypted, and able to reach a node behind a NAT through a relay ([README](packages/dactor_libp2p/README.md)).

## 🧬 Coming from Erlang/OTP

Most of OTP has a counterpart:

| Erlang/OTP | Dactor |
|------------|--------|
| `spawn`, a pid | `system.spawn`, an `ActorRef` |
| `Pid ! Msg` | `ref.tell(msg)` |
| `gen_server:call` | `ref.ask(msg)`, or `typedRef.call(request)` |
| `link`, `monitor`, `trap_exit` | `context.link`, `context.watch`, `context.trapExits` |
| `normal`, `shutdown`, `killed`, `{error, ...}`, `noproc` | `NormalExit`, `ShutdownExit`, `KilledExit`, `ErrorExit`, `NoProcExit` |
| `exit(Pid, kill)` | `system.kill(ref)` |
| `supervisor`: `one_for_one`, `one_for_all`, `rest_for_one` | `OneForOneStrategy`, `AllForOneStrategy`, `RestForOneStrategy` |
| child specs, restart intensity | `ChildSpec` with `RestartType`, `maxRestarts` within `period` |
| `gen_server`, `handle_continue` | `GenServer`, `continueWith` and `handleContinue` |
| `gen_statem` | `GenStatem`: state enter, state, event and generic timeouts, `postpone` |
| `application` | `Application` and `ApplicationController` |
| `receive` with a pattern | `context.receive<T>(where:, timeout:)` |
| `sys` | `system.sys` |
| `pg`, `global` | `ProcessGroups`, `GlobalNames` in `dactor_remote` |

Differences that come from the Dart VM:

- **No preemption.** Actors share one event loop and take turns. The pump yields every 128 messages or 4 ms, but a handler stuck in synchronous code blocks every actor in its isolate, and `kill` can only stop an actor between callbacks. Run an actor that computes, blocks, or might hang as `Isolated`: its watchdog can kill it.
- **No heap per process.** Messages are passed by reference, not copied. Send immutable values; `dactor_lints` reports mutable ones. Messages to an `Isolated` actor are copied.
- **No hot code loading.** `sys.upgrade` restarts an actor as a different class and hands its state to `codeChange`. There are no releases or relups.

Deliberate differences:

- A linked actor fails with `LinkedActorExited` instead of being killed, so its supervisor decides what happens to it.
- Senders are recorded by the runtime and cannot be forged; a `Terminated` or `ExitSignal` comes only from the runtime.
- `gen_event` has no counterpart beyond the `EventBus`, which is publish-subscribe.
- Between nodes: there is no shared cookie, and a reference carries a capability token; there is no arbitrary `rpc`, only remote spawn of a registered behaviour; a `GlobalNames` name is unique once the network is quiet, with no cluster lock.

Not there: ETS, DETS, Mnesia, `observer` and a remote shell.

## ⚡ Actor Pooling for Scalability

Scale your actors with worker pools:

```dart
// Create a pool of 4 worker actors
final router = await system.spawn(
  'worker-router',
  () => WorkerActor(),
  pool: Pool(workerCount: 4),
);

// Messages are distributed round-robin to workers
for (int i = 0; i < 100; i++) {
  router.tell('task_$i');
}
```

## ⏰ Actor Timers for Scheduled Messages

Dactor provides Akka-style Timer actors that allow you to schedule messages to be sent to an actor at specific times or intervals. Timers are automatically bound to the actor's lifecycle and are cancelled when the actor is stopped or restarted.

### Timer Types

**Single-Shot Timers**: Send a message once after a delay
```dart
class TimeoutActor extends Actor {
  @override
  void preStart() {
    // Send timeout message after 30 seconds
    context.timers.startSingleTimer(
      'timeout', 
      'session-expired', 
      Duration(seconds: 30)
    );
  }
  
  @override
  Future<void> onMessage(dynamic message) async {
    if (message == 'activity') {
      // Reset timeout on activity
      context.timers.startSingleTimer(
        'timeout', 
        'session-expired', 
        Duration(seconds: 30)
      );
    } else if (message == 'session-expired') {
      print('Session expired due to inactivity');
      context.system.stop(context.self);
    }
  }
}
```

**Fixed Delay Timers**: Send messages repeatedly with consistent spacing
```dart
class HeartbeatActor extends Actor {
  @override
  void preStart() {
    // Send heartbeat every 30 seconds with fixed delay
    context.timers.startTimerWithFixedDelay(
      'heartbeat', 
      'send-heartbeat', 
      Duration(seconds: 30)
    );
  }
  
  @override
  Future<void> onMessage(dynamic message) async {
    if (message == 'send-heartbeat') {
      await sendHeartbeatToServer();
      print('Heartbeat sent');
    }
  }
  
  Future<void> sendHeartbeatToServer() async {
    // Implementation for sending heartbeat
  }
}
```

**Fixed Rate Timers**: Send messages at exact intervals with catch-up behavior
```dart
class MetricsCollectorActor extends Actor {
  @override
  void preStart() {
    // Collect metrics every minute at fixed rate
    context.timers.startTimerAtFixedRate(
      'collect', 
      'collect-metrics', 
      Duration(minutes: 1)
    );
  }
  
  @override
  Future<void> onMessage(dynamic message) async {
    if (message == 'collect-metrics') {
      final metrics = await collectSystemMetrics();
      await storeMetrics(metrics);
    }
  }
}
```

### Timer Management

**Key-Based Timer Replacement**
```dart
class RequestTimeoutActor extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {
    if (message is StartRequest) {
      // Set timeout for this request (replaces any existing timeout)
      context.timers.startSingleTimer(
        'request-timeout',
        RequestTimeout(message.requestId),
        Duration(seconds: 5)
      );
    } else if (message is RequestCompleted) {
      // Cancel timeout as request completed successfully
      context.timers.cancel('request-timeout');
    } else if (message is RequestTimeout) {
      print('Request ${message.requestId} timed out');
    }
  }
}
```

**Timer Lifecycle Management**
```dart
class CacheManagerActor extends Actor {
  @override
  void preStart() {
    // Start periodic cleanup
    context.timers.startTimerWithFixedDelay(
      'cleanup', 'cleanup-expired', Duration(minutes: 5));
    
    // Start periodic stats collection
    context.timers.startTimerAtFixedRate(
      'stats', 'collect-stats', Duration(minutes: 1));
  }
  
  @override
  Future<void> onMessage(dynamic message) async {
    switch (message) {
      case 'cleanup-expired':
        await cleanupExpiredEntries();
        break;
      case 'collect-stats':
        await collectCacheStats();
        break;
      case 'shutdown':
        // Cancel all timers before shutdown
        context.timers.cancelAll();
        break;
    }
  }
  
  @override
  void postStop() {
    // Timers are automatically cancelled when actor stops
    print('Cache manager stopped - all timers cancelled');
  }
}
```

### Timer API Reference

```dart
// Start timers
context.timers.startSingleTimer(key, message, delay);
context.timers.startTimerWithFixedDelay(key, message, delay);
context.timers.startTimerAtFixedRate(key, message, interval);

// Manage timers  
context.timers.cancel(key);           // Cancel specific timer
context.timers.cancelAll();           // Cancel all timers
context.timers.isTimerActive(key);    // Check if timer is active
context.timers.activeTimers;          // List all active timer keys
```

### Timer Features

- **Automatic Cleanup**: Timers are automatically cancelled when actors stop or restart
- **Key-Based Replacement**: Starting a timer with an existing key cancels the previous timer
- **Lifecycle Bound**: Timer messages are guaranteed not to be received after actor termination
- **High Performance**: Built on Dart's efficient Timer implementation
- **Memory Safe**: No memory leaks from cancelled or completed timers

### Common Timer Patterns

**Session Management**
```dart
class SessionActor extends Actor {
  @override
  void preStart() {
    scheduleExpiration();
  }
  
  void scheduleExpiration() {
    context.timers.startSingleTimer(
      'expire', 'expire-session', Duration(minutes: 30));
  }
  
  @override
  Future<void> onMessage(dynamic message) async {
    switch (message) {
      case UserActivity():
        scheduleExpiration(); // Reset expiration timer
        break;
      case 'expire-session':
        print('Session expired');
        context.system.stop(context.self);
        break;
    }
  }
}
```

**Rate Limiting**
```dart
class RateLimiterActor extends Actor {
  int _requestCount = 0;
  
  @override
  void preStart() {
    // Reset counter every minute
    context.timers.startTimerAtFixedRate(
      'reset', 'reset-counter', Duration(minutes: 1));
  }
  
  @override
  Future<void> onMessage(dynamic message) async {
    if (message == 'request') {
      if (_requestCount < 100) {
        _requestCount++;
        context.sender?.tell('allowed');
      } else {
        context.sender?.tell('rate-limited');
      }
    } else if (message == 'reset-counter') {
      _requestCount = 0;
    }
  }
}
```

## 📡 Event Bus for Event-Driven Architecture

The event bus enables publish-subscribe messaging patterns for building event-driven applications:

### Basic Event Publishing and Subscription

```dart
// Define event types
class OrderCreated {
  final String orderId;
  final DateTime timestamp;
  final double amount;
  
  OrderCreated(this.orderId, this.timestamp, this.amount);
}

class PaymentProcessed {
  final String orderId;
  final double amount;
  
  PaymentProcessed(this.orderId, this.amount);
}

// Publisher actor
class OrderService extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {
    if (message == 'create_order') {
      final orderId = 'ORDER-${DateTime.now().millisecondsSinceEpoch}';
      
      // Publish event to all subscribers
      context.publish(OrderCreated(orderId, DateTime.now(), 99.99));
    }
  }
}

// Subscriber actor
class PaymentService extends Actor {
  @override
  void preStart() {
    // Subscribe to order events
    context.subscribe<OrderCreated>();
  }

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is OrderCreated) {
      print('Processing payment for order: ${message.orderId}');
      
      // Process payment and publish completion event
      context.publish(PaymentProcessed(message.orderId, message.amount));
    }
  }
}
```

### Event Bus API

```dart
// Subscribe to events (typically in preStart)
context.subscribe<OrderCreated>();

// Publish events
context.publish(OrderCreated('order-123', DateTime.now(), 99.99));

// Unsubscribe from events
context.unsubscribe<OrderCreated>();

// Direct event bus access
system.eventBus.subscribe<OrderCreated>(actorRef);
system.eventBus.publish(OrderCreated('order-123', DateTime.now(), 99.99));
system.eventBus.unsubscribe<OrderCreated>(actorRef);
```

### Event-Driven Microservices

```dart
class OrderProcessingSystem {
  late ActorSystem system;
  
  Future<void> start() async {
    system = ActorSystem.create();
    
    // Spawn services that communicate via events
    await system.spawn('order-service', () => OrderService());
    await system.spawn('payment-service', () => PaymentService());
    await system.spawn('shipping-service', () => ShippingService());
    await system.spawn('notification-service', () => NotificationService());
  }
}

class ShippingService extends Actor {
  @override
  void preStart() {
    context.subscribe<PaymentProcessed>();
  }

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is PaymentProcessed) {
      print('Shipping order: ${message.orderId}');
      context.publish(OrderShipped(message.orderId, 'TRACK-123'));
    }
  }
}

class NotificationService extends Actor {
  @override
  void preStart() {
    // Subscribe to all order events
    context.subscribe<OrderCreated>();
    context.subscribe<PaymentProcessed>();
    context.subscribe<OrderShipped>();
  }

  @override
  Future<void> onMessage(dynamic message) async {
    switch (message.runtimeType) {
      case OrderCreated:
        print('📧 Order confirmation sent');
        break;
      case PaymentProcessed:
        print('📧 Payment confirmation sent');
        break;
      case OrderShipped:
        print('📧 Shipping notification sent');
        break;
    }
  }
}
```

### Saga Pattern Implementation

```dart
class OrderSaga extends Actor {
  final Map<String, SagaState> _sagas = {};

  @override
  void preStart() {
    context.subscribe<OrderCreated>();
    context.subscribe<PaymentProcessed>();
    context.subscribe<PaymentFailed>();
    context.subscribe<OrderShipped>();
  }

  @override
  Future<void> onMessage(dynamic message) async {
    switch (message.runtimeType) {
      case OrderCreated:
        final event = message as OrderCreated;
        _sagas[event.orderId] = SagaState.orderCreated;
        // Trigger payment processing
        context.publish(ProcessPayment(event.orderId, event.amount));
        break;
        
      case PaymentProcessed:
        final event = message as PaymentProcessed;
        if (_sagas[event.orderId] == SagaState.orderCreated) {
          _sagas[event.orderId] = SagaState.paymentProcessed;
          // Trigger shipping
          context.publish(ShipOrder(event.orderId));
        }
        break;
        
      case PaymentFailed:
        final event = message as PaymentFailed;
        // Compensate: cancel order
        context.publish(CancelOrder(event.orderId));
        _sagas.remove(event.orderId);
        break;
        
      case OrderShipped:
        final event = message as OrderShipped;
        // Saga completed successfully
        _sagas.remove(event.orderId);
        break;
    }
  }
}

enum SagaState { orderCreated, paymentProcessed, shipped }
```

### Event Bus Monitoring

```dart
// Monitor event bus activity
final eventStream = system.events;
eventStream.listen((event) {
  print('Event bus activity: $event');
});

// Check event bus metrics
print('Active subscribers: ${system.eventBus.subscriberCount}');
print('Total subscriptions: ${system.eventBus.subscriptionCount}');
```

### Event Bus Features

- **Type-Safe**: Events are strongly typed using Dart's type system
- **Automatic Cleanup**: Subscriptions are automatically removed when actors stop
- **High Performance**: Efficient O(1) routing for direct type matches
- **Memory Safe**: No memory leaks from orphaned subscriptions
- **Observable**: Built-in monitoring stream for debugging and metrics

## 📊 Metrics and Observability

Built-in metrics for monitoring your actor system. By default a system collects **nothing**: metrics go to a `NoOpMetricsCollector` and traces to a `NoOpTraceCollector`, so an unconfigured system never grows with message volume. Opt in by passing a collector. The bundled `InMemoryMetricsCollector` and `InMemoryTraceCollector` are bounded (10,000 timing samples per metric and 10,000 trace events by default) and are meant for tests and local debugging; implement the `MetricsCollector` or `TraceCollector` interface to ship data elsewhere.

```dart
// Create system with metrics
final metrics = InMemoryMetricsCollector();
final system = ActorSystem.create(ActorSystemConfig(
  metricsCollector: metrics,
));

// Spawn actors and send messages...
final actor = await system.spawn('test', () => MyActor());
actor.tell('hello');

// Check metrics
print('Actors spawned: ${metrics.getCounter('actors.spawned')}');
print('Active actors: ${metrics.getGauge('actors.active')}');
print('Messages processed: ${metrics.getCounter('messages.processed')}');
print('Processing times: ${metrics.getTimings('messages.processing_time')}');
```

Available metrics:
- `actors.spawned` - Total actors created
- `actors.active` - Current active actors
- `actors.stopped` - Total actors stopped
- `actors.failed` - Total actor failures
- `messages.processed` - Total messages processed
- `messages.processing_time` - Message processing latencies
- `dead_letters` - Undeliverable messages
- `mailbox.size` - Current mailbox sizes

## 🔍 Dead Letter Queue

Handle undeliverable messages:

```dart
final actor = await system.spawn('test', () => MyActor());
await system.stop(actor);

// This message will go to dead letters
actor.tell('late_message');

// Check dead letter queue
final deadLetter = system.deadLetterQueue.dequeue();
if (deadLetter != null) {
  print('Undelivered message: ${deadLetter.message}');
  print('Intended recipient: ${deadLetter.recipient}');
}
```

## 🎮 Real-World Examples

### Chat Server

```dart
class ChatRoom extends Actor {
  final Set<ActorRef> _participants = {};

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is JoinRoom) {
      _participants.add(message.user);
      message.user.tell('Welcome to the chat!');
    } else if (message is ChatMessage) {
      // Broadcast to all participants
      for (final participant in _participants) {
        participant.tell('${message.sender}: ${message.text}');
      }
    } else if (message is LeaveRoom) {
      _participants.remove(message.user);
    }
  }
}

class JoinRoom {
  final ActorRef user;
  JoinRoom(this.user);
}

class ChatMessage {
  final String sender;
  final String text;
  ChatMessage(this.sender, this.text);
}
```

### Game Entity System

```dart
class GameEntity extends Actor {
  double x = 0, y = 0;
  int health = 100;

  @override
  Future<void> onMessage(dynamic message) async {
    switch (message.runtimeType) {
      case MoveCommand:
        final move = message as MoveCommand;
        x += move.deltaX;
        y += move.deltaY;
        // Notify other systems
        context.system.eventBus.publish(EntityMoved(context.self, x, y));
        break;
        
      case DamageCommand:
        final damage = message as DamageCommand;
        health -= damage.amount;
        if (health <= 0) {
          context.system.eventBus.publish(EntityDestroyed(context.self));
          context.stop();
        }
        break;
    }
  }
}
```

### Microservice Coordination

```dart
class OrderService extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {
    if (message is ProcessOrder) {
      try {
        // Validate order
        final validation = await context.system
            .actorOf('validation-service')
            .ask(ValidateOrder(message.order), Duration(seconds: 5));
            
        if (validation.isValid) {
          // Process payment
          final payment = await context.system
              .actorOf('payment-service')
              .ask(ProcessPayment(message.order), Duration(seconds: 10));
              
          if (payment.successful) {
            // Ship order
            context.system
                .actorOf('shipping-service')
                .tell(ShipOrder(message.order));
          }
        }
      } catch (e) {
        // Handle service failures
        context.system
            .actorOf('notification-service')
            .tell(OrderFailed(message.order, e.toString()));
      }
    }
  }
}
```

## ⚙️ Configuration

### Actor System Configuration

```dart
final config = ActorSystemConfig(
  // Ask pattern configuration
  askConfig: AskConfig(
    defaultTimeout: Duration(seconds: 5),
    maxRetries: 3,
    retryBackoffBase: Duration(milliseconds: 100),
  ),
  
  // Metrics collection
  metricsCollector: InMemoryMetricsCollector(),
  
  // Dispatcher configuration
  dispatcherConfig: DispatcherConfig(
    corePoolSize: 4,
    maximumPoolSize: 8,
  ),
);

final system = ActorSystem.create(config);
```

## 🚀 Performance

Dactor is designed for high performance:

- **Throughput**: about 500,000 messages/second to one actor; about 49,000 through a round-robin pool, whose router is the bottleneck
- **Latency**: about 25 μs per message to one actor, 8 μs through a pool
- **Memory**: about 1.7 KB per idle actor
- **Scalability**: Supports thousands of concurrent actors

Run the benchmarks:

```bash
dart test test/benchmark/
```

Results on an Apple silicon laptop, Dart 3.11, in the test runner (JIT):
```
Single Actor - Processed 100000 messages in 200ms
Single Actor - Throughput: 500000.00 msg/sec

Pooled Actor - Processed 100000 messages in 2035ms
Pooled Actor - Throughput: 49140.05 msg/sec
```

## 🧪 Testing Your Actors

The testing toolkit lives in the separate [`dactor_test`](https://pub.dev/packages/dactor_test) package so that `package:test` is not a runtime dependency of your application. The primary tools are `TestActorSystem` and `TestProbe`.

Add it as a dev dependency:

```bash
dart pub add dev:dactor_test
```

### TestActorSystem

For testing, you should use `TestActorSystem` instead of `LocalActorSystem`. It provides helper methods for creating testing utilities like probes.

```dart
import 'package:dactor/dactor.dart';
import 'package:dactor_test/dactor_test.dart';
import 'package:test/test.dart';

void main() {
  group('My Actor Tests', () {
    late TestActorSystem system;
    
    setUp(() {
      // Use TestActorSystem for your tests
      system = TestActorSystem();
    });
    
    tearDown(() async {
      await system.shutdown();
    });

    // ... your tests
  });
}
```

### TestProbe: Your Testing Companion

A `TestProbe` is a special actor that you can use to send messages to your actors and assert the replies. It acts as a "black box" test double with enhanced capabilities for robust testing.

#### Enhanced TestProbe API

The `TestProbe` provides several methods for testing actor interactions:

```dart
// Create a probe
final probe = await system.createProbe();

// Expect a specific message
await probe.expectMsg('expected_payload');

// Expect a message with timeout
await probe.expectMsg('expected_payload', timeout: Duration(seconds: 5));

// Expect a message of specific type
final msg = await probe.expectMsgType<String>();
final msg = await probe.expectMsgType<MyCustomType>(timeout: Duration(seconds: 3));

// Access the last received message
final lastMsg = probe.lastMessage;

// Send a message with the probe as the sender
probe.send(actor, 'request');

// Reply to the sender of the last message
probe.reply('response_payload');
```

#### Expecting Messages

You can use a probe to verify that your actor sends an expected message.

```dart
class MyActor extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {
    if (message == 'ping') {
      context.sender?.tell('pong');
    }
  }
}

test('should respond with pong', () async {
  // 1. Create a probe
  final probe = await system.createProbe();
  
  // 2. Spawn the actor under test
  final actor = await system.spawn('my-actor', () => MyActor());
  
  // 3. Send a message from the probe to the actor
  probe.send(actor, 'ping');
  
  // 4. Assert that the probe receives the expected reply
  await probe.expectMsg('pong');
});
```

#### Type-Safe Message Expectations

Use `expectMsgType<T>()` for type-safe message assertions:

```dart
test('should receive typed message', () async {
  final probe = await system.createProbe();
  final actor = await system.spawn('test', () => MyActor());
  
  probe.send(actor, 'get_number');
  
  // Expect a message of specific type and get it back
  final number = await probe.expectMsgType<int>(timeout: Duration(seconds: 2));
  expect(number, greaterThan(0));
});
```

#### Replying from a Probe

A probe can also reply to messages, allowing you to test more complex interactions.

```dart
class AskerActor extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {
    if (message == 'ask_and_reply') {
      final asker = context.sender;
      final response = await asker?.ask<String>('question');
      asker?.tell('response: $response');
    }
  }
}

test('should handle replies from probe', () async {
  final probe = await system.createProbe();
  final actor = await system.spawn('asker', () => AskerActor());

  probe.send(actor, 'ask_and_reply');

  // Expect the question from the actor
  await probe.expectMsg('question');
  
  // Reply from the probe
  probe.reply('answer');

  // Expect the final response
  await probe.expectMsg('response: answer');
});
```

#### Testing Best Practices

1. **Make the probe the sender**: test code runs outside any actor, so `actor.tell(message)` has no sender. Use `probe.send(actor, message)` and replies come back to the probe

2. **Use timeouts for reliability**: Always specify timeouts for `expectMsg` and `expectMsgType` in production tests

3. **Leverage type safety**: Use `expectMsgType<T>()` when you know the expected message type

4. **Access last message**: Use `probe.lastMessage` to inspect the most recent message for detailed assertions

### Deterministic Simulation

`package:dactor/simulation.dart` runs an actor system on a seeded scheduler with virtual time. One message is delivered at a time, and which actor goes next is drawn from the seed, so a test can be run under many orderings and a failure replayed exactly.

```dart
import 'package:dactor/simulation.dart';

test('transfers never lose money', () {
  explore((sim) async {
    final bank = await sim.system.spawn('bank', () => Bank());
    // ... send messages from several actors ...
    await sim.settle();                         // until every actor is idle
    await sim.wait(Duration(minutes: 5));       // virtual: returns at once
    expect(await bank.ask<int>(Total()), 1000);
  }, seeds: 1000);
});
```

When a seed fails, `explore` throws a `SimulationFailure` that names the seed and lists the last scheduling steps. `simulate(body, seed: n)` runs that one seed again, with the same result every time.

| | |
|---|---|
| `simulate(body, seed:)` | One run. Synchronous: the whole run happens inside the call and its result is returned. |
| `explore(body, seeds:)` | Many seeds, stopping at the first failure. |
| `sim.system` | The simulated `LocalActorSystem`. |
| `sim.settle()` | Completes when no actor has anything left to do at the current time. |
| `sim.wait(duration)` | Virtual sleep. `Future.delayed`, timers and timeouts are virtual as well. |
| `sim.random` | The run's random source. Take the test's own random choices from it so they replay too. |
| `sim.trace` | The scheduling decisions so far. |

**Fault injection.** Pass `faults:` to interfere with deliveries. A policy sees each user message about to be delivered and answers `Fault.none`, `Fault.drop`, `Fault.delay(duration)` or `Fault.crash`, which fails the actor with an `InjectedFault` as if its handler had thrown. `randomFaults(drop: 0.05, crash: 0.1, delay: 0.1)` does it at random, from the seed.

**Model-based tests.** `checkCommands` generates random command sequences, applies each to the actor and to a plain-Dart model, and reports the seed and the commands when they disagree. Sequences are not shrunk.

Limits:

- Only message order and time are simulated. `DateTime.now()` and `Stopwatch` read the real clock.
- Nothing outside the isolate completes inside a simulation: no sockets, files or other isolates. Waiting for one ends the run with `SimulationDeadlock`.
- Continuations of one handler run in the order Dart runs them. The scheduler reorders deliveries and timers, not microtasks.
- The simulation needs the real `LocalActorSystem`; it does not combine with `TestActorSystem`.
- Futures made outside the simulation's zone never complete inside it. The one that is easy to miss is `StreamSubscription.cancel()` on a stream created before the run, or whose controller lives outside it: awaiting it hangs the run until it ends with `SimulationLimitExceeded`. Cancel without awaiting.

### Tracing Message Flow

For more complex scenarios, you can trace the entire flow of a message through the system. This is useful for debugging and ensuring messages are processed correctly.

To enable tracing, configure your `TestActorSystem` with an `InMemoryTraceCollector`.

```dart
import 'package:dactor/dactor.dart';
import 'package:dactor_test/dactor_test.dart';
import 'package:test/test.dart';

class HelloActor extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {
    if (message == 'hello') {
      context.sender?.tell('world');
    }
  }
}

void main() {
  group('Message Tracing', () {
    late TestActorSystem system;
    late InMemoryTraceCollector collector;

    setUp(() {
      // 1. Create a collector
      collector = InMemoryTraceCollector();
      // 2. Create the system with the collector
      system = TestActorSystem(ActorSystemConfig(traceCollector: collector));
    });

    tearDown(() async => await system.shutdown());

    test('should trace message flow', () async {
      final probe = await system.createProbe();
      final actor = await system.spawn('test', () => HelloActor());

      // Send a message with the probe as the sender
      probe.send(actor, 'hello');

      // Wait for messages to be processed
      await probe.expectMsg('world');

      // 3. Inspect the trace: one id ties a message's events together
      final trace = collector.traces.values
          .firstWhere((events) => events.first.message == 'hello');
      expect(trace.length, 2);
      expect(trace[0].event, 'sent');
      expect(trace[1].event, 'processed');
    });
  });
}
```

The `InMemoryTraceCollector` stores a list of `TraceEvent` objects for each message, under an id the runtime gives it, keeping at most `maxEvents` (default 10,000) and dropping the oldest correlation ids first. Each event records what happened to the message (e.g., `sent`, `processed`, `replied`) and which actor was involved.

## 🎯 Best Practices

### 1. Design for Immutability
```dart
// Good: Immutable message
class OrderCreated {
  final String orderId;
  final DateTime timestamp;
  final List<String> items;
  
  const OrderCreated(this.orderId, this.timestamp, this.items);
}

// Avoid: Mutable state in messages
class BadMessage {
  String data; // Mutable field
  BadMessage(this.data);
}
```

### 2. Use Supervision Hierarchies
```dart
// Create supervision trees for fault isolation
final supervisor = await system.spawn('app-supervisor', () => AppSupervisor());
final dbSupervisor = await supervisor.supervise('db-supervisor', () => DbSupervisor());
final worker = await dbSupervisor.supervise('db-worker', () => DbWorker());
```

### 3. Configure Ask Pattern Appropriately
```dart
// Use development config during development
final devSystem = ActorSystem.create(ActorSystemConfig(
  askConfig: AskConfig.development(), // 30s timeout, 5 retries
));

// Use production config in production
final prodSystem = ActorSystem.create(ActorSystemConfig(
  askConfig: AskConfig.production(), // 3s timeout, 2 retries
));
```

### 4. Monitor with Metrics
```dart
// Always enable metrics in production
final system = ActorSystem.create(ActorSystemConfig(
  metricsCollector: InMemoryMetricsCollector(),
));

// Regularly check system health
Timer.periodic(Duration(minutes: 1), (_) {
  final activeActors = metrics.getGauge('actors.active');
  final failedActors = metrics.getCounter('actors.failed');
  print('System health: $activeActors active, $failedActors failed');
});
```

## 🔧 Advanced Features

### Custom Message Types
Any class will do. A sealed hierarchy lets `onMessage` switch over every case:

```dart
sealed class GameMessage {}

class PlayerMove extends GameMessage {
  final String playerId;
  final double x, y;
  PlayerMove(this.playerId, this.x, this.y);
}
```

### Actor Context Usage
```dart
class ContextActor extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {
    // Access actor context
    print('My ID: ${context.self.id}');
    print('Parent: ${context.parent?.id}');
    print('System: ${context.system}');
    
    // Create child actors
    final child = await context.actorOf('child', () => ChildActor());
    
    // Stop child actors
    await context.stop(child);
    
    // Access children
    print('Children: ${context.children.map((c) => c.id)}');
  }
}
```

## 📖 API Reference

### Core Classes

- **`Actor`** - Base class for all actors
- **`ActorRef`** - Reference to an actor for sending messages
- **`ActorSystem`** - Manages actor lifecycle and messaging
- **`EventBus`** - Manages event subscriptions and publishing
- **`SupervisorActor`** - Base class for supervising other actors
- **`TimerScheduler`** - Manages scheduled message delivery within actors

### Key Methods

**Actor System:**
- **`system.spawn(id, factory)`** - Create a new actor
- **`actor.tell(message)`** - Send fire-and-forget message
- **`actor.ask(message, timeout)`** - Send request-response message
- **`system.stop(actor)`** - Stop an actor gracefully
- **`system.shutdown()`** - Shutdown the entire system

**Event Bus:**
- **`context.publish<T>(event)`** - Publish an event to all subscribers
- **`context.subscribe<T>()`** - Subscribe to events of type T
- **`context.unsubscribe<T>()`** - Unsubscribe from events of type T
- **`system.eventBus.publish<T>(event)`** - Direct event bus publishing
- **`system.eventBus.subscribe<T>(actor)`** - Direct event bus subscription
- **`system.events`** - Stream of event bus monitoring events

**Timer Scheduler:**
- **`context.timers.startSingleTimer(key, message, delay)`** - Schedule single message
- **`context.timers.startTimerWithFixedDelay(key, message, delay)`** - Schedule with fixed delay
- **`context.timers.startTimerAtFixedRate(key, message, interval)`** - Schedule at fixed rate
- **`context.timers.cancel(key)`** - Cancel specific timer
- **`context.timers.cancelAll()`** - Cancel all timers
- **`context.timers.isTimerActive(key)`** - Check if timer is active

## 🤝 Contributing

We welcome contributions! Please see our [Contributing Guide](CONTRIBUTING.md) for details.

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- Inspired by the Akka actor system
- Built for the Dart ecosystem
- Designed for OverNode's distributed architecture

---

**Ready to build fault-tolerant, concurrent applications?** 

```bash
dart pub add dactor
```

Start building with actors today! 🚀
