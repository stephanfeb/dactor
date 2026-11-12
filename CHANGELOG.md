## Unreleased (experimental/otp-gap)

Phase 0 of `doc/otp-gap-roadmap.md`: the remaining audit items H2, H4 and H5.

- **The message pump yields to the event loop.** Dispatch used to run
  entirely in microtasks, so a mailbox backlog kept timers, I/O and `ask`
  timeouts waiting until it drained (a 1 ms timer measured at 1.4 s). The
  pump now stops after 128 messages or 4 ms in one event-loop turn and
  resumes on the next. Both limits are configurable through
  `ActorSystemConfig.maxMessagesPerTurn` and `maxTurnDuration`. Throughput is
  unchanged.
- New metric `actors.blocking_handler`, tagged with the actor id, counts
  handlers that run for longer than
  `ActorSystemConfig.blockingHandlerThreshold` (10 ms by default) before
  their first `await`.
- **`SupervisionDecision.escalate` works.** The supervisor that escalates is
  treated as having failed with the same error, and its own parent decides.
  Escalating past a top-level actor stops it. Previously escalate behaved
  like resume.
- **`spawn(supervision:)` is honoured for top-level actors.** The strategy
  now decides whether a failing top-level actor is resumed, restarted or
  stopped. Previously it was stored and ignored, and the actor was always
  stopped. Top-level actors spawned without a strategy are still stopped.
- **Stopping an actor stops its children first**, last started first. This
  includes pool workers, which used to outlive their router.
- **Restarting an actor stops its children.** The new incarnation starts
  with none; a supervisor that wants them back creates them in `preStart`,
  as `RouterActor` does.
- Failures of two children of one supervisor are handled one after the
  other. Under `AllForOneStrategy`, two children failing together used to
  restart every child twice, with the restarts interleaved.
- **A failed `preStart` rolls the spawn back.** `spawn` still rejects, but
  the id is free again, refs obtained in the meantime are dead, and
  `postStop` is not called on an actor that never started. Previously the
  actor stayed registered and processed messages uninitialised.
- An actor stopped while its `preStart` is still running gets its `postStop`
  once `preStart` completes.
- A throwing `postStop` no longer aborts `stop()` or `shutdown()`; it is
  counted as `actors.post_stop_failed` and logged.
- `Actor.onError` is now called when a handler throws, before supervision
  decides. It was documented and never invoked.
- Added `SupervisorActor.supervisedChildren`.

Phase 1, first part: a zone per actor.

- **Each actor incarnation runs in its own zone.** An error nothing caught
  (an unawaited future, a timer or stream callback) now counts as that actor
  failing and goes to supervision. Previously it reached the enclosing zone,
  which for most programs means the process-level handler.
- **Stopping or restarting an actor drops everything it left pending.**
  Timers are cancelled and code suspended on an `await` never resumes. A
  restarted actor's old incarnation can no longer act after its replacement
  has started.
- **`stop()` is graceful.** It waits for the handler in flight (or a
  `preStart` still running) before `postStop`, for at most
  `ActorSystemConfig.stopTimeout` (5 seconds by default), then kills the
  actor. Restarts wait the same way, except for the handler that failed.
  Previously `postStop` could run in the middle of a handler.
- Added `ActorSystem.kill(ref)`: stops an actor and its children at once,
  without waiting. `postStop` still runs. New metrics `actors.killed` and
  `actors.stop_timed_out`.
- **`finally` blocks around a pending `await` do not run in a killed
  actor.** Release resources in `postStop`.
- **An actor that stops itself is cut off at that call.** Code after
  `await context.system.stop(context.self)` no longer runs.
- An actor stopped during `preStart` no longer has `postStop` run later, on
  its own; the stop waits for `preStart` and then runs it.
- While a failed actor waits for its supervisor's decision it receives no
  messages, also when the failure came from outside a handler.
- Cost: an idle actor takes about 1.7 KB, up from 1.1 KB, and single-actor
  throughput is 5 to 10 percent lower.

Phase 1, second part: exit reasons and links.

- Added `ExitReason`, a sealed type saying why an actor ended: `NormalExit`
  (stopped on request), `ShutdownExit` (stopped by its parent or by system
  shutdown), `KilledExit` (`kill`, or the stop timeout ran out), `ErrorExit`
  (it failed; carries the error and stack trace) and `NoProcExit`.
- `Terminated` now has a `reason`.
- Added links: `context.link(other)` and `context.unlink(other)`. When one
  linked actor ends abnormally the other fails with `LinkedActorExited`, and
  its supervisor decides what happens to it; with no supervisor it stops,
  with the same reason. A normal exit does not propagate.
- Added `context.trapExits`. An actor that sets it receives exits of linked
  actors, normal ones included, as `ExitSignal` messages and is not brought
  down.
- A restart counts as the old incarnation ending: linked actors are
  signalled and the link is dissolved. Link in `preStart` to keep a pairing
  across restarts. Watchers are different: they are still told only when the
  actor is gone for good.

Phase 1, third part: supervisors.

- **Restart budgets belong to the supervisor, not to each child.** A
  supervisor that performs more than `maxRestarts` restarts within `period`
  (10 in 5 seconds by default), across all its children, gives up: it fails
  with `RestartLimitExceeded`, its children stop with it, and its own
  supervisor decides. Previously each child had a lifetime count of its own
  and was quietly stopped when it ran out.
- `maxRetries` and `within` on the strategies are deprecated in favour of
  `maxRestarts` and `period`. The default period is now 5 seconds; it used
  to be unlimited.
- Strategies are immutable and can be `const`. Sharing one instance between
  supervisors no longer mixes their budgets. Custom strategies should extend
  `SupervisionStrategy` rather than implement it.
- A top-level actor spawned with `supervision:` has its own budget and is
  stopped with `RestartLimitExceeded` when it runs out.
- Added `RestForOneStrategy`.
- Added `ChildSpec` and `RestartType` (`permanent`, `transient`,
  `temporary`), with `SupervisorActor.startChild`, `startChildren` and
  `terminateChild`. `supervise` takes optional `restart:` and `shutdown:`.
- **A permanent child that stops is started again.** `supervise(id, factory)`
  creates permanent children, so `system.stop(child)` on one now brings it
  back as a new actor under the same id. Use `terminateChild`, or make the
  child `transient` or `temporary`.
- **Supervision decisions go through the supervisor's mailbox**, ahead of
  its ordinary messages. `onChildFailure` no longer runs at the same time as
  the supervisor's `onMessage`.
- Added `Supervisor.onChildExited`.
- A pool router now restarts workers within the default budget and fails
  when it is exceeded; it used to restart them without limit.

Phase 1, fourth part: lints.

- Added `packages/dactor_lints`, an analyzer plugin (Dart 3.10 or later)
  with two rules, both reported by `dart analyze` and in the IDE:
  `dactor_mutable_message` (an object sent between actors has a field that
  can be reassigned) and `dactor_captured_actor_state` (an actor sends a
  closure, or itself, in a message). This repository's own code has no
  findings. See `packages/dactor_lints/README.md` for how to enable it.

Phase 2: behaviours and typed protocols. Everything here is an addition;
existing actors and `ActorRef` are unchanged.

- **`TypedRef<M>`**, from `ref.typed<M>()`: a compile-time view of an
  `ActorRef` that only accepts `M`. `Call<R>` marks a message as a request,
  and `typedRef.call(request)` returns a `Future<R>`. A handler that throws
  fails the call with `CallException` instead of leaving it to time out.
- **`GenServer<S, M>`**: `init`, `handleCall` (`Reply`, `NoReply`,
  `StopReply`), `handleCast`, `handleInfo`, `terminate`. The state is a value
  the handlers return.
- **`GenStatem<S, D, M>`**: `onEvent` answers with `next`, `keep`, `postpone`
  or `halt`; `onEnter`; state timeouts with `onTimeout`; postponed events are
  replayed in order when the state changes.
- **`Application` and `ApplicationController`**: named supervision trees
  started in dependency order and stopped in reverse.
- **Selective receive**: `context.receive<T>(where:, timeout:)` inside a
  handler. `ActorContext` gained this member, which breaks classes that
  implement `ActorContext` themselves.
- **`LocalActorSystem.sys`**: `getState`, `replaceState`, `suspend`,
  `resume`, `trace`, `statistics`, and `upgrade`, which swaps an actor's code
  and passes the old state to the new behaviour's `codeChange`.
- New metric `actors.upgraded`. `Mailbox` gained `length`, `dequeueSystem`
  and `takeFirstWhere`.
- Examples: `example/gen_server_example.dart`,
  `example/gen_statem_example.dart`. The README's first example is now the
  `GenServer` counter.

Phase 3: deterministic simulation testing.

- **`package:dactor/simulation.dart`**: `simulate` runs a test against an
  actor system on a seeded scheduler with virtual time; `explore` runs it
  under many seeds and reports the failing one with its scheduling trace.
  The same seed always gives the same run. Timers, `Future.delayed` and
  timeouts are virtual, so the runs take no real time.
- **Fault injection**: a `FaultPolicy` can drop, delay or crash on any
  delivery; `randomFaults` does so at random from the seed. A crash fails
  the actor with `InjectedFault`.
- **`checkCommands`**: model-based tests over random command sequences.
- **Watching a dead actor now delivers `Terminated`** at once, with
  `NoProcExit`, as linking to one already did. It used to do nothing, so a
  watcher that registered a moment too late waited forever. Found by the
  simulator.
- Restart budgets measure their period on the simulation's clock when run
  inside one.
- `LocalActorSystem.stepped` (internal) builds a system that dispatches
  only when told to; the pump's dispatch step is shared between both modes.
  Throughput is unchanged.

Phase 4: actors in their own isolate.

- **`Isolated(factory)`**: an actor that runs the real actor in an isolate
  of its own and forwards messages to it one at a time. It is spawned,
  supervised, linked, watched and pooled like any other actor. Messages are
  copied; `context.sender` inside the isolate reaches back with `tell` and
  `ask`.
- **Watchdog**: the isolate is pinged every `heartbeat`; one that stays
  silent for `unresponsiveAfter` is killed and the actor fails with
  `IsolateUnresponsive`, which its supervisor handles. This stops an actor
  in an infinite loop, which nothing inside one isolate can do.
- New errors `IsolateUnresponsive`, `IsolateExited`, `RemoteActorError`.
- `LocalActorSystem` and `LocalActorRef` are marked
  `vm:isolate-unsendable`. A message or closure that holds one now fails
  to send to another isolate, where it used to be copied whole.
- Probes `tool/probes/p2_isolate_kill.dart` and `p3_isolate_cost.dart`,
  and `tool/probes/isolated_throughput.dart`.
- Example: `example/isolated_example.dart`.

Phase 5, first part: remote references (in `packages/dactor_remote`).

- **`Actor.context` is no longer marked `@internal`.** The annotation made
  the analyzer warn on every use of `context` in an actor written outside
  this package, which is every actor a user writes. This is in 1.3.0 too.
- New exit reason **`NoConnectionExit`**. `ExitReason` is sealed, so an
  exhaustive `switch` over it needs the new case.
- **`ForeignActorRef`**, with `LocalActorSystem.linkForeign`,
  `unlinkForeign` and `foreignExit`: what a transport needs to link local
  actors with actors on other nodes. `context.link` accepts a
  `ForeignActorRef`.
- `Simulation.addSystem()` creates further actor systems in one simulation,
  for tests of several nodes.
- New package `packages/dactor_remote` (not published): `RemoteNode`,
  remote `tell`, `ask`, `watch` and `link`, a codec registry over CBOR,
  capability tokens, remote spawn by behaviour name, an in-memory network
  that runs under the simulator, and a plain TCP transport.

Phase 5, second part: a libp2p transport (in `packages/dactor_libp2p`).

- New package `packages/dactor_libp2p` (not published): `Libp2pTransport`
  over a dart_libp2p `Host`. Nodes are named by peer id; Noise
  authenticates them and encrypts traffic, capability tokens included.
  Nodes behind a NAT are reached through circuit relays. `startHost`
  builds a host with UDX, Noise and Yamux, with a relay role and keep-alive
  settings.
- The eleven same-as-local scenarios moved to
  `packages/dactor_remote/test/support/transport_scenarios.dart`, so every
  transport runs the same ones.

Phase 5, third part: through real NATs.

- `Libp2pTransport` moves a node's frames off a relay when a direct
  connection to it appears (after a hole punch), without losing order or
  reporting the node down. The old stream ends with an empty frame as a
  marker. New `routeTo(node)`.
- `startHost` gained `observersNeeded` (how many peers must report the same
  public address; a hole punch needs one) and `announce` (which addresses
  to advertise).
- `packages/dactor_libp2p/test/nat/run.sh`: two dactor nodes behind
  separate NAT routers in Docker, with a Ricochet server as relay (uses
  go-ricochet's mailbox Docker setup). Relay, hole punch and lost-node
  checks; cone and symmetric NATs.

Phase 5, fourth part: hardening, process groups and global names.

- Added `ActorRef.unwatch(watcher)` and `ActorContext.unwatch(actor)`. The
  context form also drops a `Terminated` from that actor still in the
  mailbox. Works on remote refs.
- Fixed: a watcher that unwatched while being told of a stop could crash
  `stop()` with a concurrent modification.
- `RemoteNode` drops the watches a lost node had placed on its actors,
  instead of keeping them until the actors end. New `watchedForOthers`.
- New `ProcessGroups` (after Erlang's `pg`) and `GlobalNames` (after
  `global`) in `dactor_remote`. Seeded simulation of 300 histories each.
- New `RemoteNode.serve` and `sendToService`: messages between nodes, with
  the sending node authenticated by the transport.
- `InMemoryNetwork` fixed: a frame lost to a partition could be followed by
  later frames on the same pair with no node-down in between, if the
  partition healed before the loss was noticed. That broke the transport's
  promise ("in order, or nothing, and then a node-down"). Now nothing passes
  between two nodes from the loss until it is reported.
- `dactor_libp2p` requires dart_libp2p 4.12.1, which fixes the socket leak
  that kept processes from exiting. The examples and tools no longer call
  `exit`.
- TCP heartbeats are still not done: a silent, still-open TCP connection is
  not detected (libp2p's keep-alive does detect it).

## 1.3.0

- **`ask()` no longer retries by default.** `AskConfig()` now has
  `enableRetries: false`. A retry re-sends the request, so with the old
  default a slow (not failed) actor executed the same command up to four
  times, and an ask to a dead actor blocked the caller for about 20 s.
  `AskConfig.development()` and `AskConfig.production()` still enable
  retries explicitly. Retries keep the same `correlationId` across attempts so
  receivers can deduplicate.
- Fixed the Quick Start in the README and `example/dactor_example.dart`. Both
  tested `message is LocalMessage` inside `onMessage`, which is never true
  because actors receive the payload; the counter never incremented and the
  ask timed out. They now switch on the payload and reply via
  `context.sender`.
- Removed the unused `cbor` dependency and the "zero dependencies" claim.
- Added a `.pubignore` so `doc/` and repository tooling are not published.
- **A system built without a config no longer collects metrics or traces.**
  The previous defaults, `InMemoryMetricsCollector` and
  `InMemoryTraceCollector`, kept a timing sample for every message and a
  trace event (holding the payload) for every send and receive, forever;
  measured at roughly 485 MB retained per million messages. The defaults are
  now `NoOpMetricsCollector` and `NoOpTraceCollector`. Pass an explicit
  collector to opt in. Also added `NoOpLogCollector`.
- `InMemoryMetricsCollector` and `InMemoryTraceCollector` are now bounded
  (`maxTimings` per metric and `maxEvents` overall, both 10,000 by default).
  The tracer evicts whole correlation ids, oldest first, and exposes
  `eventCount` and `clear()`; `traces` is now a read-only view.
- `dactor.dart` now exports the metrics, tracing, logging and routing
  libraries (`Pool`, `RoutingLogic`, the collectors, `LogRecord`, ...), which
  already appeared in public signatures but could only be imported from
  `src/`.
- **Supervision is routed by an explicit parent record, not by parsing `/` in
  the actor id.** Previously the system took everything before the last `/`
  as the supervisor and cast it with `as SupervisorActor`; an actor named
  `plain/evil` under a non-supervisor `plain` therefore killed the whole
  process with an unhandled `TypeError` on its first failure, and any actor
  could attach itself to a foreign supervisor by choosing its name. Children
  are now created through `SupervisorActor.supervise` (internally
  `LocalActorSystem.spawnChild`), which records the parent, requires the
  parent to be a live `Supervisor`, and rejects child ids that are empty or
  contain `/`. Actors spawned with a `/` in their id through `spawn` are
  ordinary unsupervised actors. `RouterActor` supervises its workers through
  the same path. Added `test/supervision_guard_test.dart`.
- **Restart now happens in place.** Previously a restart stopped the actor and
  spawned a new one, which created a new `ActorRef`; every reference held by
  other actors (including pool workers) then went to dead letters, pending
  messages were discarded, watchers received `Terminated`, and event-bus
  subscriptions were lost. A restart now keeps the ref, mailbox, watchers and
  subscriptions and only replaces the `Actor` instance: `postStop` on the old
  one, timers cancelled, `preStart` on the new one. `SupervisorActor` and
  `RouterActor` use this path. Messages are never dispatched to an actor
  whose `preStart` has not completed. Added `test/restart_test.dart`.
- Errors thrown while handling a child failure (for example a replacement's
  `preStart` throwing) no longer escape as unhandled zone errors. The child is
  stopped, `actors.supervision_failed` is incremented and the error is logged.
- Add `dactor_test` as a dev dependency. The 1.2.0 release moved the test
  toolkit out of this package but never declared it, so 9 of the 12 test files
  could not load from a clean checkout. Added a GitHub Actions workflow that
  runs `dart analyze` and the unit tests on every push and pull request.
- README: the testing section now points at the `dactor_test` package.
- Fix `shutdown()` not stopping any actor. `stop()` returned early once the
  shutdown flag was set, so `postStop` never ran, timers kept firing (keeping
  the isolate alive), refs stayed `isAlive`, and late messages were silently
  queued instead of dead-lettered. Actors are now torn down in reverse spawn
  order during shutdown. Added `test/shutdown_test.dart`.

## 1.2.0

- Fix actor model correctness, supervision, and messaging issues
- Remove `test` from regular dependencies (was incorrectly listed as runtime dep)
- Extract test utilities into separate `dactor_test` package

## 1.1.0

- **Docs**: Added comprehensive documentation for testing actors, including `TestActorSystem`, `TestProbe`, and message tracing.

## 1.0.0

- Initial version.
