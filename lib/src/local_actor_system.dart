import 'dart:async';
import 'dart:collection';

import 'package:meta/meta.dart';

import 'package:dactor/src/actor.dart';
import 'package:dactor/src/actor_ref.dart';
import 'package:dactor/src/actor_zone.dart';
import 'package:dactor/src/actor_system.dart';
import 'package:dactor/src/local_actor_ref.dart';
import 'package:dactor/src/local_message.dart';
import 'package:dactor/src/message.dart';
import 'package:dactor/src/dead_letter_queue.dart';
import 'package:dactor/src/mailbox.dart';
import 'package:dactor/src/metrics/metrics.dart';
import 'package:dactor/src/logging/logging.dart';
import 'package:dactor/src/ask_config.dart';
import 'package:dactor/src/tracing/tracing.dart';
import 'package:dactor/src/supervision.dart';
import 'package:dactor/src/routing/pool.dart';
import 'package:dactor/src/routing/router_actor.dart';
import 'package:dactor/src/event_bus.dart';
import 'package:dactor/src/exit_reason.dart';
import 'package:dactor/src/timer_scheduler.dart';
import 'package:dactor/src/dactor_timer_scheduler.dart';

/// One run of an actor: the [Actor] instance a factory produced, and the zone
/// all of its code runs in. A restart retires one incarnation and starts the
/// next.
class _Incarnation extends TombstoneZone {
  final LocalActorSystem system;
  final String id;
  final Actor actor;

  /// `preStart` completed, so this incarnation is owed a `postStop`.
  bool preStarted = false;
  bool postStopped = false;

  /// A handler threw (or an error escaped the zone) and supervision has not
  /// yet decided what to do.
  bool failed = false;

  /// A stop or restart has claimed this incarnation.
  bool retiring = false;

  /// `preStart` or a message handler is in progress.
  bool busy = false;

  /// Settles the bookkeeping of the handler in flight. Called when the zone
  /// is killed, because that handler's future will then never complete.
  void Function()? abandon;

  /// Why this incarnation is ending, once that is known: set when it fails
  /// or is killed, cleared again if supervision resumes it.
  ExitReason? exitReason;

  /// The actors this incarnation is linked with.
  Set<LocalActorRef>? links;

  Completer<void>? _idle;

  _Incarnation(this.system, this.id, this.actor) : super(system._systemZone);

  @override
  void onUncaughtError(Object error, StackTrace stackTrace) =>
      system._onZoneError(this, error, stackTrace);

  Future<void> get idle => (_idle ??= Completer<void>()).future;

  void markIdle() {
    busy = false;
    _idle?.complete();
    _idle = null;
  }
}

/// Everything the system knows about one actor *cell*: the identity that
/// survives restarts (mailbox, factory, strategy) plus the current
/// incarnation, which a restart replaces.
class _ActorInfo {
  _Incarnation inc;
  final Actor Function() factory;
  final SupervisionStrategy? supervision;
  final Mailbox mailbox;

  /// Id of the supervising parent, or null for an unsupervised actor. This is
  /// the only source of truth for failure routing; the `/` in an actor's id is
  /// a naming convention, not a relationship.
  final String? parentId;

  /// False until the current incarnation's `preStart` has completed. The pump
  /// leaves the mailbox alone while this is false so no message reaches an
  /// actor that has not finished initialising.
  bool started = false;

  /// True while the current incarnation has failed and its supervisor is
  /// still deciding. The pump delivers nothing in the meantime.
  bool suspended = false;

  /// Ids of the actors this one supervises, in start order. Stopping or
  /// restarting this actor stops them first, last-started first.
  final children = <String>{};

  /// Tail of the chain of supervision decisions this actor is making for its
  /// children. Failures of two children are handled one after the other, never
  /// interleaved.
  Future<void>? supervisionTail;

  /// Set once teardown has begun; a second stop waits on the first.
  Future<void>? stopping;

  /// Set while a restart is in progress; a second restart joins the first.
  Future<void>? restarting;

  _ActorInfo(this.inc, this.factory, this.supervision, this.mailbox,
      {this.parentId});

  Actor get actor => inc.actor;
}

class LocalActorSystem implements ActorSystem {
  final _actors = <String, LocalActorRef>{};
  final _actorInfo = <String, _ActorInfo>{};
  final _activeMailboxes = Queue<Mailbox>();
  final _scheduledMailboxes = <Mailbox>{};
  final _processingActors = <String>{};
  late final DeadLetterQueue deadLetterQueue;
  late final EventBus _eventBus;
  @override
  final MetricsCollector metrics;
  @override
  final TraceCollector tracer;
  @override
  final LogCollector logger;

  /// Configuration for ask pattern behavior.
  final AskConfig askConfig;

  /// The zone the system was created in. The pump and all lifecycle work run
  /// here, and every actor zone is forked from it, so killing one actor's
  /// zone can never cut short the system's own bookkeeping or another actor.
  final Zone _systemZone = Zone.current;

  /// How long a stop or restart waits for a handler in flight.
  final Duration _stopTimeout;

  bool _isShutdown = false;
  Completer<void> _pumpSignal = Completer<void>();

  /// Most messages dispatched in one event-loop turn before the pump yields.
  final int _maxMessagesPerTurn;

  /// Longest the pump keeps dispatching in one event-loop turn, in
  /// microseconds, before it yields.
  final int _maxTurnMicros;

  /// A handler that runs synchronously for longer than this, in microseconds,
  /// is counted as `actors.blocking_handler`.
  final int _blockingHandlerMicros;

  /// Measures how long the pump has held the current event-loop turn.
  final _turnClock = Stopwatch();
  int _turnCount = 0;
  bool _turnOpen = false;

  LocalActorSystem([ActorSystemConfig? config])
      : metrics = config?.metricsCollector ?? const NoOpMetricsCollector(),
        tracer = config?.traceCollector ?? const NoOpTraceCollector(),
        logger = config?.logCollector ?? ConsoleLogCollector(),
        askConfig = config?.askConfig ?? AskConfig(),
        _stopTimeout = config?.stopTimeout ?? const Duration(seconds: 5),
        _maxMessagesPerTurn = config?.maxMessagesPerTurn ?? 128,
        _maxTurnMicros =
            (config?.maxTurnDuration ?? const Duration(milliseconds: 4))
                .inMicroseconds,
        _blockingHandlerMicros = (config?.blockingHandlerThreshold ??
                const Duration(milliseconds: 10))
            .inMicroseconds {
    deadLetterQueue = DeadLetterQueue(metrics,
        maxSize: config?.deadLetterQueueMaxSize ?? 1000);
    _eventBus = EventBus();
    _messagePump();
  }

  @override
  EventBus get eventBus => _eventBus;

  @override
  Stream<EventBusEvent> get events => _eventBus.events;

  /// Runs synchronous lifecycle work in the system zone.
  R _sys<R>(R Function() f) =>
      identical(Zone.current, _systemZone) ? f() : _systemZone.run(f);

  /// Runs asynchronous lifecycle work in the system zone on behalf of a
  /// caller in another zone.
  ///
  /// Actors call spawn, stop and restart from inside their own zones. If the
  /// awaits inside those operations were bound to the caller's zone, killing
  /// the caller would strand them halfway, so the work runs here.
  ///
  /// The result is handed back through a completer created in the caller's
  /// zone. That matters for errors: Dart does not deliver a future's error to
  /// a listener in a different error zone, so awaiting the system-zone future
  /// directly from an actor would hang on failure.
  Future<T> _sysAsync<T>(Future<T> Function() f) {
    if (identical(Zone.current, _systemZone)) {
      return f();
    }
    final completer = Completer<T>();
    _systemZone.run(() {
      try {
        f().then(completer.complete, onError: completer.completeError);
      } catch (e, s) {
        completer.completeError(e, s);
      }
    });
    return completer.future;
  }

  /// Runs [body] in [inc]'s zone.
  ///
  /// A synchronous [body] returns (or throws) directly. An asynchronous one
  /// is handed back as a future that belongs to the system zone, for the same
  /// reason as [_sysAsync] in the other direction. If the zone is killed
  /// first, that future never completes; race it against
  /// [TombstoneZone.killed].
  FutureOr<T> _inActor<T>(_Incarnation inc, FutureOr<T> Function() body) {
    Completer<T>? completer;
    final result = inc.run<FutureOr<T>>(() {
      final result = body();
      if (result is Future<T>) {
        // Created in the system zone on purpose: a future delivers its
        // error only to listeners in the error zone it was created in.
        final Completer<T> bridge = _systemZone.run(() => Completer<T>());
        completer = bridge;
        result.then(bridge.complete, onError: bridge.completeError);
      }
      return result;
    });
    return completer?.future ?? result;
  }

  /// The incarnation whose code is running right now, if any.
  _Incarnation? get _caller {
    final zone = Zone.current;
    if (identical(zone, _systemZone)) return null;
    final owner = TombstoneZone.of(zone);
    return owner is _Incarnation && identical(owner.system, this)
        ? owner
        : null;
  }

  @override
  Future<ActorRef> spawn<T extends Actor>(
    String id,
    T Function() actorFactory, {
    SupervisionStrategy? supervision,
    Pool? pool,
  }) {
    return spawnAndGetActor(
      id,
      pool != null ? () => RouterActor(pool, actorFactory) : actorFactory,
      supervision: supervision,
    ).then((spawned) => spawned.ref);
  }

  Future<({ActorRef ref, Actor actor})> spawnAndGetActor<T extends Actor>(
    String id,
    T Function() actorFactory, {
    SupervisionStrategy? supervision,
  }) {
    return _sysAsync(() => _spawn(id, actorFactory, supervision: supervision));
  }

  /// Spawns `'$parentId/$childId'` as a supervised child of [parentId].
  ///
  /// This is the only way to create a supervised actor. [parentId] must name
  /// a live [Supervisor]; [childId] must be a single path segment.
  @internal
  Future<ActorRef> spawnChild(
    String parentId,
    String childId,
    Actor Function() actorFactory, {
    SupervisionStrategy? supervision,
  }) {
    return _sysAsync(() async {
      if (childId.isEmpty || childId.contains('/')) {
        throw ArgumentError.value(
            childId, 'childId', 'must be a non-empty single path segment');
      }
      final parent = _actorInfo[parentId];
      if (parent == null || parent.actor is! Supervisor) {
        throw ArgumentError.value(
            parentId, 'parentId', 'is not a live Supervisor');
      }
      final spawned = await _spawn('$parentId/$childId', actorFactory,
          supervision: supervision, parentId: parentId);
      return spawned.ref;
    });
  }

  /// The live children of the actor with [id], in start order.
  @internal
  List<ActorRef> childrenOf(String id) {
    final info = _actorInfo[id];
    if (info == null) return const [];
    return [
      for (final childId in info.children)
        if (_actors[childId] case final ref?) ref
    ];
  }

  Future<({ActorRef ref, Actor actor})> _spawn(
    String id,
    Actor Function() actorFactory, {
    SupervisionStrategy? supervision,
    String? parentId,
  }) async {
    if (_isShutdown) {
      throw StateError('Actor system is shutdown');
    }
    if (id.isEmpty) {
      throw ArgumentError.value(id, 'id', 'must not be empty');
    }
    if (_actors.containsKey(id)) {
      throw ArgumentError('Actor with id $id already exists');
    }

    final actor = actorFactory();
    final mailbox = Mailbox(id, scheduleMailbox, onGauge: metrics.gauge);
    final actorRef =
        LocalActorRef(id, mailbox, deadLetterQueue, tracer, askConfig);
    final info = _ActorInfo(
        _newIncarnation(id, actor), actorFactory, supervision, mailbox,
        parentId: parentId);

    _actors[id] = actorRef;
    _actorInfo[id] = info;
    if (parentId != null) {
      _actorInfo[parentId]?.children.add(id);
    }

    try {
      await _startIncarnation(info, actorRef);
    } catch (e, s) {
      // preStart failed: the actor never existed. Free the id and release
      // whatever was registered, without running postStop on an actor that
      // did not finish initialising.
      metrics.increment('actors.start_failed', tags: {'actorId': id});
      if (identical(_actorInfo[id], info)) {
        await _stopActor(actorRef, reason: ErrorExit(e, s));
      }
      rethrow;
    }
    metrics.increment('actors.spawned');
    metrics.gauge('actors.active', _actors.length.toDouble());

    return (ref: actorRef, actor: actor);
  }

  _Incarnation _newIncarnation(String id, Actor actor) =>
      _Incarnation(this, id, actor);

  /// An error nothing caught surfaced in an actor's zone: an unawaited future
  /// failed, or a timer or stream callback threw. It counts as that actor
  /// failing, exactly as if a message handler had thrown.
  void _onZoneError(_Incarnation inc, Object error, StackTrace stackTrace) {
    final info = _actorInfo[inc.id];
    final actorRef = _actors[inc.id];
    if (info == null || actorRef == null || !identical(info.inc, inc)) {
      return;
    }
    _systemZone.run(() {
      _fail(info, actorRef, inc, error, stackTrace);
    });
  }

  /// Wires a fresh context into the current incarnation, runs its `preStart`
  /// inside its zone, and only then opens the mailbox for processing.
  Future<void> _startIncarnation(
      _ActorInfo info, LocalActorRef actorRef) async {
    final inc = info.inc;
    inc.actor.context = _ActorContext(actorRef, this);
    inc.busy = true;
    try {
      final starting = _inActor<void>(inc, () => inc.actor.preStart());
      if (starting is Future<void>) {
        // If the zone is killed, preStart's future never completes.
        await Future.any([starting, inc.killed]);
      }
    } finally {
      inc.markIdle();
    }
    if (inc.isDead) {
      return;
    }
    inc.preStarted = true;
    if (inc.retiring || !_isCurrent(info, inc)) {
      // A stop or restart arrived while preStart was running and has been
      // waiting for it; that operation runs postStop.
      return;
    }
    info.started = true;
    info.suspended = false;
    if (!info.mailbox.isEmpty) {
      scheduleMailbox(info.mailbox);
    }
  }

  /// True while [inc] is the running incarnation of the registered cell
  /// [info].
  bool _isCurrent(_ActorInfo info, _Incarnation inc) =>
      identical(_actorInfo[info.mailbox.actorId], info) &&
      identical(info.inc, inc);

  void _disposeTimers(Actor actor) {
    final timers = actor.context.timers;
    if (timers is DactorTimerScheduler) {
      timers.dispose();
    }
  }

  /// Ends [inc]: runs `postStop` if it is owed one, then switches its zone
  /// off so that nothing it left behind can run. Idempotent.
  ///
  /// The caller follows up with [_signalLinks], once anything that watchers
  /// should hear about first has been done.
  void _finishRetire(_Incarnation inc, String id) {
    inc.retiring = true;
    _disposeTimers(inc.actor);
    if (inc.preStarted && !inc.postStopped && !inc.isDead) {
      inc.postStopped = true;
      try {
        inc.run(() => inc.actor.postStop());
      } catch (e) {
        // One bad hook must not abort a stop, a restart or a shutdown.
        metrics.increment('actors.post_stop_failed', tags: {'actorId': id});
        logger.record(LogRecord(LogLevel.error, 'postStop of $id threw: $e'));
      }
    }
    inc.kill();
    inc.abandon?.call();
  }

  /// Tells every actor linked with [inc] that it has ended, and dissolves
  /// the links.
  void _signalLinks(_Incarnation inc, LocalActorRef from, ExitReason reason) {
    final links = inc.links;
    if (links == null) return;
    inc.links = null;
    for (final peerRef in links) {
      final peerInfo = _actorInfo[peerRef.id];
      if (peerInfo == null || !identical(_actors[peerRef.id], peerRef)) {
        continue;
      }
      peerInfo.inc.links?.remove(from);
      _deliverExit(peerInfo, peerRef, from, reason);
    }
  }

  /// Delivers an exit signal about [from] to the current incarnation of
  /// [info].
  void _deliverExit(_ActorInfo info, LocalActorRef actorRef, ActorRef from,
      ExitReason reason) {
    final inc = info.inc;
    if (_isShutdown || inc.retiring || inc.isDead) return;
    if ((inc.actor.context as _ActorContext).trapExits) {
      actorRef.tell(LocalMessage(payload: ExitSignal(from, reason)));
    } else if (!reason.isNormal) {
      _fail(info, actorRef, inc, LinkedActorExited(from, reason),
          StackTrace.current,
          reason: reason);
    }
  }

  void _link(_ActorContext context, ActorRef other) {
    final self = context.self;
    if (other.id == self.id) return;
    if (other is! LocalActorRef) {
      throw ArgumentError.value(
          other, 'other', 'is not an actor of this system');
    }
    _sys(() {
      final info = _actorInfo[self.id];
      final actorRef = _actors[self.id];
      // A context that outlived its incarnation links nothing.
      if (info == null ||
          actorRef == null ||
          !identical(info.inc.actor.context, context) ||
          info.inc.retiring) {
        return;
      }
      final peerInfo = _actorInfo[other.id];
      if (peerInfo == null ||
          !identical(_actors[other.id], other) ||
          peerInfo.inc.retiring) {
        _deliverExit(info, actorRef, other, const NoProcExit());
        return;
      }
      (info.inc.links ??= {}).add(other);
      (peerInfo.inc.links ??= {}).add(actorRef);
    });
  }

  void _unlink(_ActorContext context, ActorRef other) {
    final info = _actorInfo[context.self.id];
    final actorRef = _actors[context.self.id];
    if (info == null ||
        actorRef == null ||
        !identical(info.inc.actor.context, context)) {
      return;
    }
    info.inc.links?.remove(other);
    if (identical(_actors[other.id], other)) {
      _actorInfo[other.id]?.inc.links?.remove(actorRef);
    }
  }

  /// Whether a graceful stop or restart should wait for [inc] to finish what
  /// it is doing. It does not wait for a handler that has already failed, nor
  /// for the handler that is itself asking for the stop.
  bool _mustWait(_Incarnation inc, _Incarnation? requester) =>
      inc.busy && !inc.failed && !identical(inc, requester);

  /// Waits for [inc] to finish `preStart` or the handler in flight, for at
  /// most [_stopTimeout].
  Future<void> _awaitIdle(_Incarnation inc, String id) {
    return inc.idle.timeout(_stopTimeout, onTimeout: () {
      inc.exitReason ??= const KilledExit();
      metrics.increment('actors.stop_timed_out', tags: {'actorId': id});
      logger.record(LogRecord(
          LogLevel.warning,
          '$id did not finish its current handler within '
          '${_stopTimeout.inMilliseconds} ms and was killed'));
    });
  }

  /// Dispatches messages until shutdown.
  ///
  /// Dispatch itself only ever schedules microtasks, so a backlog would keep
  /// timers and I/O waiting until it drained. The pump therefore works in
  /// turns: after [_maxMessagesPerTurn] messages or [_maxTurnMicros] in one
  /// event-loop turn, it yields through a zero-duration timer and lets the
  /// event loop run.
  void _messagePump() async {
    while (!_isShutdown) {
      if (_activeMailboxes.isEmpty) {
        await _waitForWork();
        continue;
      }
      final mailbox = _activeMailboxes.removeFirst();
      _scheduledMailboxes.remove(mailbox);

      if (mailbox.isDisposed) {
        continue;
      }

      final info = _actorInfo[mailbox.actorId];
      if (info == null || !info.started || info.suspended) {
        // Not runnable right now; whoever makes it runnable reschedules.
        continue;
      }

      final message = mailbox.dequeue();
      if (message == null) {
        continue;
      }
      metrics.increment('messages.processed');
      final actorRef = _actors[mailbox.actorId]!;

      _openTurn();
      final before = _turnClock.elapsedMicroseconds;
      _processingActors.add(mailbox.actorId);
      _processMessage(info, actorRef, message);
      final after = _turnClock.elapsedMicroseconds;

      // _processMessage returns at the handler's first suspension, so this
      // is the time the handler held the isolate without yielding.
      if (after - before > _blockingHandlerMicros) {
        metrics.increment('actors.blocking_handler',
            tags: {'actorId': mailbox.actorId});
      }

      if (++_turnCount >= _maxMessagesPerTurn || after >= _maxTurnMicros) {
        await Future<void>.delayed(Duration.zero);
      }
    }
  }

  /// Starts counting a new turn if the event loop has run since the last one.
  ///
  /// The sentinel timer fires on the next event-loop turn, which is the only
  /// reliable sign that timers and I/O have had a chance to run. Until then
  /// every message counts against the same budget, however many times the
  /// pump went idle and was woken by a microtask in between.
  void _openTurn() {
    if (_turnOpen) return;
    _turnOpen = true;
    _turnCount = 0;
    _turnClock
      ..reset()
      ..start();
    Timer.run(() => _turnOpen = false);
  }

  /// Hands one message to the actor, inside the actor's zone, without
  /// blocking the pump: the handler may `await` (an `ask`, for instance) and
  /// other actors keep running meanwhile.
  ///
  /// The handler's future is observed from the system zone. If the actor is
  /// killed that future never completes, so the kill settles the bookkeeping
  /// through [_Incarnation.abandon] instead.
  void _processMessage(
      _ActorInfo info, LocalActorRef actorRef, Message message) {
    final stopwatch = Stopwatch()..start();
    // Pin the incarnation that handles this message; a restart during the
    // handler must not redirect the bookkeeping below to the replacement.
    final inc = info.inc;
    final actor = inc.actor;
    final mailbox = info.mailbox;
    final context = actor.context as _ActorContext;

    var finished = false;
    void finish() {
      if (finished) return;
      finished = true;
      inc.abandon = null;
      stopwatch.stop();
      metrics.timing('messages.processing_time', stopwatch.elapsed);
      context.sender = null;
      _processingActors.remove(mailbox.actorId);
      inc.markIdle();
      if (!mailbox.isEmpty && !mailbox.isDisposed) {
        scheduleMailbox(mailbox);
      }
    }

    void failed(Object error, StackTrace stackTrace) {
      _fail(info, actorRef, inc, error, stackTrace).whenComplete(finish);
    }

    inc.busy = true;
    inc.abandon = finish;

    final Object? payload;
    if (message is LocalMessage) {
      context.sender = message.sender;
      tracer.record(TraceEvent(
          message.correlationId, 'processed', actorRef, message.payload));
      payload = message.payload;
    } else {
      payload = message;
    }

    // The outcome is observed from inside the actor's zone, because a
    // listener outside it would never be told about an error, and then
    // carried back to the system zone, where the bookkeeping lives.
    try {
      inc.run(() {
        actor.onMessage(payload).then((_) => _systemZone.run(finish),
            onError: (Object e, StackTrace s) =>
                _systemZone.run(() => failed(e, s)));
      });
    } catch (e, s) {
      failed(e, s);
    }
  }

  void scheduleMailbox(Mailbox mailbox) {
    if (_processingActors.contains(mailbox.actorId)) {
      return;
    }
    if (_scheduledMailboxes.add(mailbox)) {
      _activeMailboxes.add(mailbox);
      _wakeUpPump();
    }
  }

  void _wakeUpPump() {
    if (!_pumpSignal.isCompleted) {
      _pumpSignal.complete();
    }
  }

  Future<void> _waitForWork() async {
    _pumpSignal = Completer<void>();
    await _pumpSignal.future;
  }

  /// Records that [inc] failed with [error] and sees supervision through.
  ///
  /// Reached two ways: a message handler threw, or an error escaped the
  /// actor's zone. Only the first failure of an incarnation counts; while its
  /// supervisor decides, the actor receives nothing. Never throws.
  ///
  /// [reason] is the exit reason the actor ends with if supervision stops or
  /// restarts it. It defaults to an [ErrorExit] carrying [error].
  Future<void> _fail(_ActorInfo info, LocalActorRef actorRef, _Incarnation inc,
      Object error, StackTrace stackTrace,
      {ExitReason? reason}) async {
    if (inc.failed || inc.retiring || inc.isDead || !_isCurrent(info, inc)) {
      return;
    }
    inc.failed = true;
    inc.exitReason = reason ?? ErrorExit(error, stackTrace);
    info.suspended = true;
    metrics.increment('actors.failed');
    try {
      inc.run(() => inc.actor.onError(error, stackTrace));
    } catch (_) {
      // The hook is informational; supervision decides what happens.
    }
    try {
      await _handleFailure(info, actorRef, inc, error, stackTrace);
    } catch (supervisionError) {
      // Supervision itself failed (for example the replacement's preStart
      // threw). Nobody awaits this, so contain it and give up on the child.
      metrics.increment('actors.supervision_failed',
          tags: {'actorId': actorRef.id});
      logger.record(LogRecord(
          LogLevel.error,
          'Supervision of ${actorRef.id} failed after $error: '
          '$supervisionError',
          actor: actorRef));
      try {
        await _stopActor(actorRef);
      } catch (_) {}
    }
    if (_isCurrent(info, inc) && !inc.retiring) {
      // Resumed: same incarnation, same state, next message.
      inc.failed = false;
      inc.exitReason = null;
      info.suspended = false;
      if (!info.mailbox.isEmpty) {
        scheduleMailbox(info.mailbox);
      }
    }
  }

  /// Decides what happens to [failed], the incarnation of [info] that failed.
  ///
  /// A supervised actor is handed to its parent's `onChildFailure`. If the
  /// parent answers [SupervisionDecision.escalate], the parent is treated as
  /// having failed with the same error and the decision moves one level up.
  /// A top-level actor is governed by the strategy it was spawned with, and
  /// is stopped if it has none or if the failure escalates past the top.
  Future<void> _handleFailure(_ActorInfo info, LocalActorRef actorRef,
      _Incarnation failed, Object error, StackTrace stackTrace) async {
    final parentId = info.parentId;
    final parentInfo = parentId == null ? null : _actorInfo[parentId];

    if (parentInfo != null && parentInfo.actor is Supervisor) {
      // One decision at a time per supervisor: a second child failing while
      // the first is still being restarted waits its turn.
      final previous = parentInfo.supervisionTail;
      final done = Completer<void>();
      parentInfo.supervisionTail = done.future;
      try {
        if (previous != null) await previous;
        // An earlier decision (all-for-one, a cascade) may already have
        // replaced or stopped this incarnation.
        if (!_isCurrent(info, failed) || failed.retiring) return;
        final parentInc = parentInfo.inc;
        final parent = parentInc.actor;
        final parentRef = _actors[parentId];
        if (parent is! Supervisor ||
            parentRef == null ||
            parentInc.isDead ||
            !identical(_actorInfo[parentId], parentInfo)) {
          await _stopActor(actorRef);
          return;
        }
        // The decision is the supervisor's code, so it runs in the
        // supervisor's zone. If the supervisor dies meanwhile, its children
        // go with it and this never needs an answer.
        final deciding = _inActor<SupervisionDecision>(parentInc,
            () => parent.onChildFailure(actorRef, error, stackTrace));
        final decision = deciding is Future<SupervisionDecision>
            ? await Future.any<SupervisionDecision?>(
                [deciding, parentInc.killed.then((_) => null)])
            : deciding;
        if (decision == SupervisionDecision.escalate) {
          metrics.increment('actors.escalated', tags: {'actorId': actorRef.id});
          await _handleFailure(
              parentInfo, parentRef, parentInc, error, stackTrace);
        }
      } finally {
        done.complete();
      }
      return;
    }

    final strategy = parentId == null ? info.supervision : null;
    final decision = strategy == null
        ? SupervisionDecision.stop
        : strategy.handle(actorRef.id, error, stackTrace);
    switch (decision) {
      case SupervisionDecision.resume:
        break;
      case SupervisionDecision.restart:
        await _restartActor(actorRef.id);
      case SupervisionDecision.stop:
      case SupervisionDecision.escalate:
        // Nothing sits above a top-level actor, so escalating stops it.
        await _stopActor(actorRef);
    }
  }

  /// [ActorContext.restart], called from inside an actor's zone.
  Future<void> _restartFrom(String id) {
    final requester = _caller;
    return _sysAsync(() => _restartActor(id, requester: requester));
  }

  /// Restarts the actor with [id] in place.
  ///
  /// The [LocalActorRef], its mailbox (including every pending message),
  /// watchers and event-bus subscriptions are kept. Only the incarnation is
  /// replaced: the old one is allowed to finish the handler it is in (see
  /// [_mustWait]), its `postStop` runs, its zone is switched off, and
  /// `preStart` runs on the new one before any further message is delivered.
  /// The message that triggered the failure is not redelivered.
  ///
  /// Children do not survive: they are stopped before the old incarnation's
  /// `postStop`, and the new incarnation starts with none. A supervisor that
  /// wants its children back creates them in `preStart`.
  Future<void> _restartActor(String id, {_Incarnation? requester}) {
    final actorRef = _actors[id];
    final info = _actorInfo[id];
    if (_isShutdown ||
        actorRef == null ||
        info == null ||
        info.stopping != null) {
      return Future<void>.value();
    }
    return info.restarting ??= _doRestart(actorRef, info, requester)
        .whenComplete(() => info.restarting = null);
  }

  Future<void> _doRestart(
      LocalActorRef actorRef, _ActorInfo info, _Incarnation? requester) async {
    final id = actorRef.id;
    metrics.increment('actors.restarted', tags: {'actorId': id});

    info.started = false;
    final old = info.inc;
    old.retiring = true;
    if (_mustWait(old, requester)) {
      await _awaitIdle(old, id);
    }
    if (info.children.isNotEmpty) {
      await _stopChildren(info, requester);
    }
    _finishRetire(old, id);
    _signalLinks(old, actorRef, old.exitReason ?? const ShutdownExit());
    if (info.stopping != null || !identical(_actorInfo[id], info)) {
      return;
    }

    try {
      info.inc = _newIncarnation(id, info.factory());
      await _startIncarnation(info, actorRef);
    } catch (e, s) {
      // The replacement could not initialise; there is nothing left to run.
      if (identical(_actorInfo[id], info)) {
        await _stopActor(actorRef, reason: ErrorExit(e, s));
      }
      rethrow;
    }
  }

  /// Stops [actor] gracefully.
  ///
  /// The actor receives no further messages. A handler already in flight is
  /// given [ActorSystemConfig.stopTimeout] to finish; then the actor's
  /// children are stopped, its `postStop` runs, and its zone is switched off,
  /// which drops anything it left pending (timers, unawaited futures, a
  /// handler that did not finish in time).
  ///
  /// An actor that stops itself is not waited for: its handler is cut off at
  /// its next `await`.
  @override
  Future<void> stop(ActorRef actor) {
    if (_isShutdown) {
      return Future<void>.value();
    }
    final requester = _caller;
    return _sysAsync(() => _stopActor(actor, requester: requester));
  }

  /// Stops [actor] and its children immediately, without waiting for
  /// handlers in flight.
  ///
  /// `postStop` still runs, because it is the only place an actor can release
  /// what it holds: `finally` blocks around a pending `await` do not run in a
  /// killed actor.
  @override
  void kill(ActorRef actor) {
    if (_isShutdown) {
      return;
    }
    final actorRef = _actors[actor.id];
    final info = _actorInfo[actor.id];
    if (actorRef == null || info == null) {
      return;
    }
    metrics.increment('actors.killed', tags: {'actorId': actor.id});
    _sys(() => _killTree(actorRef, info));
  }

  void _killTree(LocalActorRef actorRef, _ActorInfo info) {
    info.started = false;
    for (final childId in info.children.toList().reversed) {
      final child = _actors[childId];
      final childInfo = _actorInfo[childId];
      if (child != null && childInfo != null) {
        _killTree(child, childInfo);
      }
    }
    info.children.clear();
    final inc = info.inc;
    _finishRetire(inc, actorRef.id);
    _finishStop(actorRef, info, const KilledExit());
    _signalLinks(inc, actorRef, const KilledExit());
  }

  /// Stops every child of [info], last-started first.
  Future<void> _stopChildren(_ActorInfo info, _Incarnation? requester) async {
    for (final childId in info.children.toList().reversed) {
      final child = _actors[childId];
      if (child != null) {
        await _stopActor(child,
            requester: requester, reason: const ShutdownExit());
      }
    }
    info.children.clear();
  }

  /// Stops [actor] regardless of the shutdown flag.
  ///
  /// [stop] refuses work once shutdown has begun, but [shutdown] itself must
  /// still be able to tear every actor down, so it calls this directly.
  ///
  /// [reason] is reported to watchers and linked actors, unless the actor has
  /// a reason of its own: it failed, or it had to be killed.
  Future<void> _stopActor(ActorRef actor,
      {_Incarnation? requester, ExitReason reason = const NormalExit()}) {
    final actorRef = _actors[actor.id];
    if (actorRef is! LocalActorRef) {
      metrics.increment('actors.stop_failed');
      deadLetterQueue.enqueue(
          LocalMessage(payload: 'Message to non-existent actor: ${actor.id}'));
      return Future<void>.value();
    }
    final info = _actorInfo[actor.id];
    if (info == null) {
      _finishStop(actorRef, null, reason);
      return Future<void>.value();
    }
    return info.stopping ??= _tearDown(actorRef, info, requester, reason);
  }

  Future<void> _tearDown(LocalActorRef actorRef, _ActorInfo info,
      _Incarnation? requester, ExitReason requested) async {
    info.started = false;
    final inc = info.inc;
    inc.retiring = true;
    // With nothing in flight and no children this runs to completion without
    // suspending, so a caller that does not await stop() still sees the
    // actor gone.
    if (_mustWait(inc, requester)) {
      await _awaitIdle(inc, actorRef.id);
    }
    if (info.children.isNotEmpty) {
      await _stopChildren(info, requester);
    }
    final reason = inc.exitReason ?? requested;
    _finishRetire(inc, actorRef.id);
    _finishStop(actorRef, info, reason);
    _signalLinks(inc, actorRef, reason);
  }

  /// Unregisters the actor. Idempotent, because a kill can overtake a
  /// graceful stop that is still waiting.
  void _finishStop(
      LocalActorRef actorRef, _ActorInfo? info, ExitReason reason) {
    if (!identical(_actors[actorRef.id], actorRef)) {
      return;
    }
    _eventBus.cleanup(actorRef);
    actorRef.stop(reason);
    _actors.remove(actorRef.id);
    _actorInfo.remove(actorRef.id);
    final parentId = info?.parentId;
    if (parentId != null) {
      _actorInfo[parentId]?.children.remove(actorRef.id);
    }
    metrics.gauge('actors.active', _actors.length.toDouble());
    metrics.increment('actors.stopped');
  }

  @override
  ActorRef? getActor(String id) {
    if (_isShutdown) {
      return null;
    }
    return _actors[id];
  }

  @override
  Future<void> shutdown() {
    if (_isShutdown) {
      return Future<void>.value();
    }
    _isShutdown = true;
    final requester = _caller;
    return _sysAsync(() => _shutdown(requester));
  }

  Future<void> _shutdown(_Incarnation? requester) async {
    _wakeUpPump();
    metrics.increment('system.shutdown');
    // Stop in reverse spawn order so children (spawned after their parents)
    // are torn down before the actors that created them.
    for (final actorRef in List<LocalActorRef>.of(_actors.values).reversed) {
      // A parent's teardown may already have taken this actor with it.
      if (identical(_actors[actorRef.id], actorRef)) {
        await _stopActor(actorRef,
            requester: requester, reason: const ShutdownExit());
      }
    }
    _actors.clear();
    _actorInfo.clear();
    deadLetterQueue.dispose();
    _eventBus.dispose();
  }
}

class _ActorContext implements ActorContext {
  @override
  final ActorRef self;
  @override
  final LocalActorSystem system;
  @override
  ActorRef? sender;
  @override
  late final TimerScheduler timers;

  _ActorContext(this.self, this.system) {
    timers = DactorTimerScheduler(self);
  }

  @override
  Future<ActorRef> spawn<T extends Actor>(
      String id, T Function() actorFactory) {
    return system.spawn(id, actorFactory);
  }

  @override
  void watch(ActorRef actor) {
    actor.watch(self);
  }

  @override
  bool trapExits = false;

  @override
  void link(ActorRef other) => system._link(this, other);

  @override
  void unlink(ActorRef other) => system._unlink(this, other);

  @override
  Future<void> restart(ActorRef child) {
    return system._restartFrom(child.id);
  }

  @override
  void publish<T>(T event) {
    system.eventBus.publish<T>(event);
  }

  @override
  void subscribe<T>() {
    system.eventBus.subscribe<T>(self);
  }

  @override
  void unsubscribe<T>() {
    system.eventBus.unsubscribe<T>(self);
  }
}
