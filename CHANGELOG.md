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
