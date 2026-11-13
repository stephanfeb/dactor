// The system calls the lifecycle hooks that actors and supervisors protect.
// ignore_for_file: invalid_use_of_protected_member
import 'dart:async';
import 'dart:collection';

import 'package:meta/meta.dart';

import 'package:dactor/src/actor.dart';
import 'package:dactor/src/actor_ref.dart';
import 'package:dactor/src/actor_zone.dart';
import 'package:dactor/src/actor_system.dart';
import 'package:dactor/src/local_actor_ref.dart';
import 'package:dactor/src/sending.dart';
import 'package:dactor/src/dead_letter_queue.dart';
import 'package:dactor/src/mailbox.dart';
import 'package:dactor/src/metrics/metrics.dart';
import 'package:dactor/src/logging/logging.dart';
import 'package:dactor/src/ask_config.dart';
import 'package:dactor/src/tracing/tracing.dart';
import 'package:dactor/src/supervision.dart';
import 'package:dactor/src/system_messages.dart';
import 'package:dactor/src/sys.dart';
import 'package:dactor/src/routing/pool.dart';
import 'package:dactor/src/routing/router_actor.dart';
import 'package:dactor/src/event_bus.dart';
import 'package:dactor/src/exit_reason.dart';
import 'package:dactor/src/timer_scheduler.dart';
import 'package:dactor/src/dactor_timer_scheduler.dart';

/// A message from the system to a supervisor, delivered through the
/// supervisor's mailbox ahead of its user messages and never passed to
/// `onMessage`.
sealed class _SupervisionSignal {}

/// A child failed and is waiting, suspended, for a decision.
final class _ChildFailed extends _SupervisionSignal {
  final LocalActorRef child;
  final _ActorInfo info;
  final _Incarnation inc;
  final Object error;
  final StackTrace stackTrace;

  /// Completed by the supervisor's slot with what it decided.
  final decision = Completer<SupervisionDecision>();

  _ChildFailed(this.child, this.info, this.inc, this.error, this.stackTrace);
}

/// A child is gone for good.
final class _ChildExited extends _SupervisionSignal {
  final LocalActorRef child;
  final ExitReason reason;
  _ChildExited(this.child, this.reason);
}

/// A request from [Sys], delivered through the actor's mailbox ahead of its
/// user messages and never passed to `onMessage`.
sealed class _SysRequest {
  /// Created in the caller's zone, so the caller hears about errors.
  final done = Completer<Object?>();
}

final class _GetState extends _SysRequest {}

final class _ReplaceState extends _SysRequest {
  final Object? Function(Object? current) update;
  _ReplaceState(this.update);
}

/// What a stepped system is about to hand to an actor.
@internal
class StepDelivery {
  final LocalActorRef target;
  final Envelope message;

  /// True for supervision signals and `sys` requests, which are delivered
  /// whatever the hook answers.
  final bool isSystem;
  StepDelivery(this.target, this.message, this.isSystem);
}

/// What to do with a [StepDelivery].
@internal
enum StepFault {
  /// Deliver it.
  none,

  /// Take it out of the mailbox and do not deliver it.
  skip,

  /// Take it out of the mailbox and fail the actor as if its handler threw
  /// an [InjectedFault].
  crash,
}

/// The error an actor fails with when a simulation makes it crash.
class InjectedFault implements Exception {
  final ActorRef actor;

  /// The message the actor was about to handle. It is lost, as it would be
  /// if the handler had thrown.
  final Object? message;

  const InjectedFault(this.actor, this.message);

  @override
  String toString() => 'InjectedFault: ${actor.id} was made to crash';
}

/// A handler waiting in [ActorContext.receive].
class _PendingReceive {
  final bool Function(Object? payload) test;
  final Completer<Object?> done;
  _PendingReceive(this.test, this.done);
}

/// One run of an actor: the [Actor] instance a factory produced, and the zone
/// all of its code runs in. A restart retires one incarnation and starts the
/// next.
class _Incarnation extends TombstoneZone {
  final LocalActorSystem system;
  final String id;
  final Actor actor;

  @override
  ActorRef? get self {
    try {
      return actor.context.self;
    } on Error {
      // No context yet: the constructor is still running.
      return null;
    }
  }

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
  Set<ActorRef>? links;

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
  Actor Function() factory;
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

  /// Whether any incarnation ever completed `preStart`. An actor that never
  /// started was never really there, and its supervisor is not told it left.
  bool everStarted = false;

  /// True while the current incarnation has failed and its supervisor is
  /// still deciding. The pump delivers nothing in the meantime.
  bool suspended = false;

  /// Ids of the actors this one supervises, in start order. Stopping or
  /// restarting this actor stops them first, last-started first.
  final children = <String>{};

  /// Set by [Sys.suspend]: user messages wait, system messages still run.
  bool sysSuspended = false;

  /// Set by [Sys.trace].
  bool traced = false;

  int processed = 0;
  int restarts = 0;

  /// A handler of the current incarnation waiting in `receive`.
  _PendingReceive? pendingReceive;

  /// Restart budget of a top-level actor spawned with a strategy. Supervised
  /// actors draw on their supervisor's budget instead.
  RestartBudget? budget;

  /// How long a stop or restart waits for this actor's handler in flight, if
  /// that differs from the system default.
  Duration? stopTimeout;

  /// Set once teardown has begun; a second stop waits on the first.
  Future<void>? stopping;

  /// Set while a restart is in progress; a second restart joins the first.
  Future<void>? restarting;

  _ActorInfo(this.inc, this.factory, this.supervision, this.mailbox,
      {this.parentId});

  Actor get actor => inc.actor;
}

// Never copied into another isolate by accident: a message or closure that
// holds one fails to send instead.
@pragma('vm:isolate-unsendable')
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

  /// False for a system whose messages are dispatched one at a time by
  /// [step] instead of by the pump.
  final bool _pumped;

  LocalActorSystem([ActorSystemConfig? config]) : this._(config, true);

  /// A system that dispatches nothing by itself. Whoever owns it calls
  /// [runnableActors] and [step] to choose what runs next. This is what the
  /// simulation in `package:dactor/simulation.dart` is built on.
  @internal
  LocalActorSystem.stepped([ActorSystemConfig? config]) : this._(config, false);

  LocalActorSystem._(ActorSystemConfig? config, this._pumped)
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
    if (_pumped) _messagePump();
  }

  /// Inspection and control of running actors.
  late final Sys sys = _Sys(this);

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
    Duration? stopTimeout,
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
          supervision: supervision,
          parentId: parentId,
          stopTimeout: stopTimeout);
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
    Duration? stopTimeout,
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
        parentId: parentId)
      ..stopTimeout = stopTimeout;

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
  Future<void> _startIncarnation(_ActorInfo info, LocalActorRef actorRef,
      {BehaviourHandoff? handoff}) async {
    final inc = info.inc;
    inc.actor.context = _ActorContext(actorRef, this).._handoff = handoff;
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
    info.everStarted = true;
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
    final info = _actorInfo[id];
    if (info != null && identical(info.inc, inc)) {
      info.pendingReceive = null;
    }
  }

  /// Tells every actor linked with [inc] that it has ended, and dissolves
  /// the links.
  void _signalLinks(_Incarnation inc, LocalActorRef from, ExitReason reason) {
    final links = inc.links;
    if (links == null) return;
    inc.links = null;
    for (final peerRef in links) {
      if (peerRef is ForeignActorRef) {
        peerRef.linkedExit(from, reason);
        continue;
      }
      if (peerRef is! LocalActorRef) continue;
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
      Sending.system(actorRef, ExitSignal(from, reason));
    } else if (!reason.isNormal) {
      _fail(info, actorRef, inc, LinkedActorExited(from, reason),
          StackTrace.current,
          reason: reason);
    }
  }

  /// Records, on behalf of another node, that [foreign] has linked with the
  /// local actor [local]. Returns false if [local] is not alive, in which
  /// case nothing was recorded.
  ///
  /// For transports. It does not call back into [foreign].
  bool linkForeign(ActorRef local, ForeignActorRef foreign) => _sys(() {
        final info = _actorInfo[local.id];
        if (info == null ||
            !identical(_actors[local.id], local) ||
            info.inc.retiring ||
            info.inc.isDead) {
          return false;
        }
        (info.inc.links ??= {}).add(foreign);
        return true;
      });

  /// Forgets a link recorded by [linkForeign] or made by `context.link`.
  /// For transports. It does not call back into [foreign].
  void unlinkForeign(ActorRef local, ForeignActorRef foreign) {
    if (identical(_actors[local.id], local)) {
      _actorInfo[local.id]?.inc.links?.remove(foreign);
    }
  }

  /// Tells the local actor [local] that [foreign], which it was linked
  /// with, has ended, and dissolves the link. Does nothing if they were not
  /// linked. For transports.
  void foreignExit(
          ActorRef local, ForeignActorRef foreign, ExitReason reason) =>
      _sys(() {
        final info = _actorInfo[local.id];
        final actorRef = _actors[local.id];
        if (info == null || actorRef == null || !identical(actorRef, local)) {
          return;
        }
        if (info.inc.links?.remove(foreign) ?? false) {
          _deliverExit(info, actorRef, foreign, reason);
        }
      });

  void _link(_ActorContext context, ActorRef other) {
    final self = context.self;
    if (other.id == self.id) return;
    if (other is! LocalActorRef && other is! ForeignActorRef) {
      throw ArgumentError.value(
          other, 'other', 'is not an actor this system can link to');
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
      if (other is ForeignActorRef) {
        if ((info.inc.links ??= {}).add(other)) other.linkFrom(actorRef);
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
    final removed = info.inc.links?.remove(other) ?? false;
    if (other is ForeignActorRef) {
      if (removed) other.unlinkFrom(actorRef);
      return;
    }
    if (identical(_actors[other.id], other)) {
      _actorInfo[other.id]?.inc.links?.remove(actorRef);
    }
  }

  /// Whether a graceful stop or restart should wait for [inc] to finish what
  /// it is doing. It does not wait for a handler that has already failed, nor
  /// for the handler that is itself asking for the stop.
  bool _mustWait(_ActorInfo info, _Incarnation inc, _Incarnation? requester) =>
      inc.busy &&
      !inc.failed &&
      !identical(inc, requester) &&
      info.stopTimeout != Duration.zero;

  /// Waits for [inc] to finish `preStart` or the handler in flight, for at
  /// most the actor's stop timeout.
  Future<void> _awaitIdle(_ActorInfo info, _Incarnation inc, String id) {
    final timeout = info.stopTimeout ?? _stopTimeout;
    return inc.idle.timeout(timeout, onTimeout: () {
      inc.exitReason ??= const KilledExit();
      metrics.increment('actors.stop_timed_out', tags: {'actorId': id});
      logger.record(LogRecord(
          LogLevel.warning,
          '$id did not finish its current handler within '
          '${timeout.inMilliseconds} ms and was killed'));
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
      if (!_dispatch(mailbox, null)) continue;
      final after = _turnClock.elapsedMicroseconds;

      if (++_turnCount >= _maxMessagesPerTurn || after >= _maxTurnMicros) {
        await Future<void>.delayed(Duration.zero);
      }
    }
  }

  /// Whether the pump could hand [mailbox]'s actor a message right now.
  bool _isRunnable(Mailbox mailbox) {
    if (mailbox.isDisposed) return false;
    final info = _actorInfo[mailbox.actorId];
    if (info == null || !info.started || info.suspended) return false;
    return info.sysSuspended ? mailbox.hasSystemMessages : !mailbox.isEmpty;
  }

  /// Takes the next message from [mailbox] and hands it to the actor.
  /// Returns false if there was nothing to hand over.
  bool _dispatch(Mailbox mailbox, StepFault Function(StepDelivery)? fault) {
    // The same test as [_isRunnable], spelled out: this is the hot path.
    if (mailbox.isDisposed) return false;
    final info = _actorInfo[mailbox.actorId];
    if (info == null || !info.started || info.suspended) {
      // Whoever makes it runnable reschedules.
      return false;
    }
    final message =
        info.sysSuspended ? mailbox.dequeueSystem() : mailbox.dequeue();
    if (message == null) return false;
    final actorRef = _actors[mailbox.actorId]!;

    var crash = false;
    if (fault != null) {
      final payload = message.payload;
      final isSystem = payload is _SupervisionSignal || payload is _SysRequest;
      final decided = fault(StepDelivery(actorRef, message, isSystem));
      // System messages are shown to the hook, never interfered with.
      switch (isSystem ? StepFault.none : decided) {
        case StepFault.none:
          break;
        case StepFault.skip:
          if (!mailbox.isEmpty) scheduleMailbox(mailbox);
          return true;
        case StepFault.crash:
          crash = true;
      }
    }

    info.processed++;
    metrics.increment('messages.processed');
    if (_pumped) _openTurn();
    final before = _turnClock.elapsedMicroseconds;
    _processingActors.add(mailbox.actorId);
    _processMessage(info, actorRef, message, crash: crash);

    // _processMessage returns at the handler's first suspension, so this
    // is the time the handler held the isolate without yielding.
    if (_turnClock.elapsedMicroseconds - before > _blockingHandlerMicros) {
      metrics.increment('actors.blocking_handler',
          tags: {'actorId': mailbox.actorId});
    }
    return true;
  }

  /// The ids of the actors that have a message waiting and are free to
  /// handle it, in the order the pump would serve them.
  @internal
  List<String> get runnableActors {
    assert(!_pumped);
    _activeMailboxes.removeWhere((mailbox) {
      if (_isRunnable(mailbox)) return false;
      _scheduledMailboxes.remove(mailbox);
      return true;
    });
    return [for (final mailbox in _activeMailboxes) mailbox.actorId];
  }

  /// Hands the actor [actorId] its next message. [fault] sees every delivery
  /// and may interfere with those of user messages.
  @internal
  void step(String actorId, {StepFault Function(StepDelivery)? fault}) {
    assert(!_pumped);
    final mailbox = _actorInfo[actorId]?.mailbox;
    if (mailbox == null || !_scheduledMailboxes.remove(mailbox)) {
      throw StateError('$actorId has nothing to run');
    }
    _activeMailboxes.remove(mailbox);
    _sys(() => _dispatch(mailbox, fault));
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
      _ActorInfo info, LocalActorRef actorRef, Envelope message,
      {bool crash = false}) {
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
      // A receive the handler did not wait for ends with the handler.
      if (identical(info.inc, inc)) info.pendingReceive = null;
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

    final payload = message.payload;
    context.sender = message.sender;
    tracer.record(TraceEvent(message.traceId, 'processed', actorRef, payload));
    if (info.traced &&
        payload is! _SupervisionSignal &&
        payload is! _SysRequest) {
      logger.record(
          LogRecord(LogLevel.debug, 'received $payload', actor: actorRef));
    }

    // The outcome is observed from inside the actor's zone, because a
    // listener outside it would never be told about an error, and then
    // carried back to the system zone, where the bookkeeping lives.
    try {
      inc.run(() {
        final Future<void> handling = switch (payload) {
          _SupervisionSignal() =>
            _superviseSignal(actor as Supervisor, payload),
          _SysRequest() => _answerSys(actor, payload),
          _ when crash => Future<void>.error(
              InjectedFault(actorRef, payload), StackTrace.current),
          _ => actor.onMessage(payload),
        };
        handling.then((_) => _systemZone.run(finish),
            onError: (Object e, StackTrace s) =>
                _systemZone.run(() => failed(e, s)));
      });
    } catch (e, s) {
      failed(e, s);
    }
  }

  /// Answers a [_SysRequest] as one of the actor's own messages.
  Future<void> _answerSys(Object actor, _SysRequest request) async {
    try {
      switch (request) {
        case _GetState():
          request.done.complete(
              actor is StatefulBehaviour ? actor.behaviourState : actor);
        case _ReplaceState():
          if (actor is! StatefulBehaviour) {
            throw UnsupportedError(
                '${actor.runtimeType} does not keep its state as a value');
          }
          actor.behaviourState = request.update(actor.behaviourState);
          request.done.complete(actor.behaviourState);
      }
    } catch (e, s) {
      request.done.completeError(e, s);
    }
  }

  /// Drops every [Terminated] from [watched] waiting in [watcher]'s mailbox.
  void _flushTerminated(ActorRef watcher, ActorRef watched) {
    final mailbox = _actorInfo[watcher.id]?.mailbox;
    if (mailbox == null) return;
    bool isFrom(Envelope message) {
      final payload = message.payload;
      return payload is Terminated && payload.actor == watched;
    }

    while (mailbox.takeFirstWhere(isFrom) != null) {}
  }

  /// Gives a handler waiting in `receive` the first queued message it
  /// accepts. Returns whether it got one.
  bool _feedReceive(_ActorInfo info) {
    final pending = info.pendingReceive;
    if (pending == null) return false;
    final match =
        info.mailbox.takeFirstWhere((message) => pending.test(message.payload));
    if (match == null) return false;
    info.pendingReceive = null;
    // From here on the handler answers the message it received.
    (info.inc.actor.context as _ActorContext).sender = match.sender;
    pending.done.complete(match.payload);
    return true;
  }

  Future<T> _receive<T>(_ActorContext context, bool Function(T message)? where,
      Duration? timeout) {
    // Created here, in the actor's zone: its timeout dies with the actor.
    final done = Completer<Object?>();
    final info = _actorInfo[context.self.id];
    if (info == null ||
        !identical(info.inc.actor.context, context) ||
        !info.inc.busy) {
      throw StateError('receive can only be called from inside a handler');
    }
    if (info.pendingReceive != null) {
      throw StateError('this handler is already waiting in receive');
    }
    final pending = _PendingReceive(
        (payload) => payload is T && (where == null || where(payload)), done);
    info.pendingReceive = pending;
    _sys(() => _feedReceive(info));
    var waiting = done.future.then((payload) => payload as T);
    if (timeout != null) {
      waiting = waiting.timeout(timeout, onTimeout: () {
        if (identical(info.pendingReceive, pending)) {
          info.pendingReceive = null;
        }
        throw TimeoutException('No matching message arrived', timeout);
      });
    }
    return waiting;
  }

  void scheduleMailbox(Mailbox mailbox) {
    if (_processingActors.contains(mailbox.actorId)) {
      // Busy, but perhaps busy waiting for exactly this message.
      final info = _actorInfo[mailbox.actorId];
      if (info != null && info.pendingReceive != null) {
        _sys(() => _feedReceive(info));
      }
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

  /// Handles a [_SupervisionSignal] as one of the supervisor's messages.
  /// Runs in the supervisor's zone, in its mailbox slot, so it never overlaps
  /// the supervisor's `onMessage` or another signal.
  Future<void> _superviseSignal(
      Supervisor supervisor, _SupervisionSignal signal) async {
    switch (signal) {
      case _ChildFailed():
        if (!_isCurrent(signal.info, signal.inc) || signal.inc.retiring) {
          // An earlier decision (all-for-one, a cascade) already replaced or
          // stopped this incarnation.
          signal.decision.complete(SupervisionDecision.resume);
          return;
        }
        try {
          signal.decision.complete(await supervisor.onChildFailure(
              signal.child, signal.error, signal.stackTrace));
        } on RestartLimitExceeded {
          // The supervisor has given up: it fails, as if this handler threw.
          signal.decision.complete(SupervisionDecision.stop);
          rethrow;
        } catch (e, s) {
          // A bug in the supervisor's own decision. The child cannot be left
          // suspended; the system stops it and the supervisor carries on.
          signal.decision.completeError(e, s);
        }
      case _ChildExited():
        await supervisor.onChildExited(signal.child, signal.reason);
    }
  }

  /// Decides what happens to [failed], the incarnation of [info] that failed.
  ///
  /// A supervised actor's failure is sent to its parent as a system message
  /// and answered by the parent's `onChildFailure`. If the parent answers
  /// [SupervisionDecision.escalate], the parent is treated as having failed
  /// with the same error and the decision moves one level up. A top-level
  /// actor is governed by the strategy it was spawned with, and is stopped if
  /// it has none or if the failure escalates past the top.
  Future<void> _handleFailure(_ActorInfo info, LocalActorRef actorRef,
      _Incarnation failed, Object error, StackTrace stackTrace) async {
    final parentId = info.parentId;
    if (parentId != null) {
      final parentInfo = _actorInfo[parentId];
      final parentRef = _actors[parentId];
      if (parentInfo == null ||
          parentRef == null ||
          parentInfo.actor is! Supervisor ||
          parentInfo.mailbox.isDisposed) {
        // The supervisor is gone: nobody is left to decide.
        await _stopActor(actorRef);
        return;
      }
      final signal = _ChildFailed(actorRef, info, failed, error, stackTrace);
      parentInfo.mailbox.enqueueSystem(Envelope(signal, null));
      // If the supervisor dies before it answers, this never completes; its
      // children are stopped along with it.
      final decision = await signal.decision.future;
      if (!_isCurrent(info, failed) || failed.retiring) return;
      switch (decision) {
        case SupervisionDecision.escalate:
          metrics.increment('actors.escalated', tags: {'actorId': actorRef.id});
          if (_isCurrent(parentInfo, parentInfo.inc)) {
            await _fail(
                parentInfo, parentRef, parentInfo.inc, error, stackTrace);
          }
        case SupervisionDecision.stop:
          await _stopActor(actorRef);
        case SupervisionDecision.resume:
        case SupervisionDecision.restart:
          break;
      }
      return;
    }

    final strategy = info.supervision;
    var decision = strategy == null
        ? SupervisionDecision.stop
        : strategy.handle(actorRef.id, error, stackTrace);
    if (decision == SupervisionDecision.restart && strategy != null) {
      final budget =
          info.budget ??= RestartBudget(strategy.maxRestarts, strategy.period);
      if (!budget.record()) {
        metrics.increment('actors.restart_limit_exceeded',
            tags: {'actorId': actorRef.id});
        failed.exitReason = ErrorExit(
            RestartLimitExceeded(actorRef.id, actorRef.id, error,
                strategy.maxRestarts, strategy.period),
            stackTrace);
        decision = SupervisionDecision.stop;
      }
    }
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
  ///
  /// With [upgradeTo], later incarnations come from that factory, and the
  /// first of them is handed the old incarnation's state.
  Future<void> _restartActor(String id,
      {_Incarnation? requester, Actor Function()? upgradeTo}) {
    final actorRef = _actors[id];
    final info = _actorInfo[id];
    if (_isShutdown ||
        actorRef == null ||
        info == null ||
        info.stopping != null) {
      return Future<void>.value();
    }
    if (upgradeTo != null && info.restarting != null) {
      throw StateError('$id is being restarted; try the upgrade again');
    }
    return info.restarting ??= _doRestart(actorRef, info, requester, upgradeTo)
        .whenComplete(() => info.restarting = null);
  }

  Future<void> _doRestart(LocalActorRef actorRef, _ActorInfo info,
      _Incarnation? requester, Actor Function()? upgradeTo) async {
    final id = actorRef.id;
    metrics.increment(
        upgradeTo == null ? 'actors.restarted' : 'actors.upgraded',
        tags: {'actorId': id});
    info.restarts++;

    info.started = false;
    final old = info.inc;
    old.retiring = true;
    if (_mustWait(info, old, requester)) {
      await _awaitIdle(info, old, id);
    }
    if (info.children.isNotEmpty) {
      await _stopChildren(info, requester);
    }
    // The old incarnation is idle now, or was given up on: its state is as
    // settled as it will get.
    BehaviourHandoff? handoff;
    final Object oldActor = old.actor;
    if (upgradeTo != null && oldActor is StatefulBehaviour && old.preStarted) {
      handoff = (
        version: oldActor.behaviourVersion,
        state: oldActor.behaviourState,
      );
    }
    _finishRetire(old, id);
    _signalLinks(old, actorRef, old.exitReason ?? const ShutdownExit());
    if (info.stopping != null || !identical(_actorInfo[id], info)) {
      return;
    }

    try {
      if (upgradeTo != null) info.factory = upgradeTo;
      info.inc = _newIncarnation(id, info.factory());
      await _startIncarnation(info, actorRef, handoff: handoff);
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

  /// Stops [child] on behalf of its supervisor: like [stop], but the child
  /// ends with [ShutdownExit].
  @internal
  Future<void> stopChild(ActorRef child) {
    if (_isShutdown) {
      return Future<void>.value();
    }
    final requester = _caller;
    return _sysAsync(() =>
        _stopActor(child, requester: requester, reason: const ShutdownExit()));
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
      deadLetterQueue.enqueue(DeadLetter('stop', null, actor));
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
    if (_mustWait(info, inc, requester)) {
      await _awaitIdle(info, inc, actorRef.id);
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
      final parent = _actorInfo[parentId];
      if (parent != null) {
        parent.children.remove(actorRef.id);
        // Tell the supervisor, unless it is on its way out itself.
        if (!_isShutdown &&
            info!.everStarted &&
            parent.actor is Supervisor &&
            !parent.inc.retiring &&
            parent.stopping == null) {
          parent.mailbox
              .enqueueSystem(Envelope(_ChildExited(actorRef, reason), null));
        }
      }
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

class _Sys implements Sys {
  final LocalActorSystem _system;
  _Sys(this._system);

  _ActorInfo _info(ActorRef actor) {
    final info = _system._actorInfo[actor.id];
    if (info == null || !identical(_system._actors[actor.id], actor)) {
      throw StateError('Actor ${actor.id} is not alive');
    }
    return info;
  }

  Future<Object?> _ask(ActorRef actor, _SysRequest request, Duration? timeout) {
    _info(actor).mailbox.enqueueSystem(Envelope(request, null));
    return request.done.future.timeout(timeout ?? _system._stopTimeout,
        onTimeout: () {
      throw TimeoutException(
          'Actor ${actor.id} did not answer the sys request', timeout);
    });
  }

  @override
  Future<Object?> getState(ActorRef actor, {Duration? timeout}) =>
      _ask(actor, _GetState(), timeout);

  @override
  Future<Object?> replaceState(
          ActorRef actor, Object? Function(Object? current) update,
          {Duration? timeout}) =>
      _ask(actor, _ReplaceState(update), timeout);

  @override
  void suspend(ActorRef actor) => _info(actor).sysSuspended = true;

  @override
  void resume(ActorRef actor) {
    final info = _info(actor);
    info.sysSuspended = false;
    if (!info.mailbox.isEmpty) {
      _system.scheduleMailbox(info.mailbox);
    }
  }

  @override
  void trace(ActorRef actor, bool enabled) => _info(actor).traced = enabled;

  @override
  ActorStatistics statistics(ActorRef actor) {
    final info = _info(actor);
    return ActorStatistics(
      messagesProcessed: info.processed,
      mailboxSize: info.mailbox.length,
      restarts: info.restarts,
      suspended: info.sysSuspended,
      busy: info.inc.busy,
    );
  }

  @override
  Future<void> upgrade(ActorRef actor, Actor Function() newFactory) {
    _info(actor);
    final requester = _system._caller;
    return _system._sysAsync(() => _system._restartActor(actor.id,
        requester: requester, upgradeTo: newFactory));
  }
}

class _ActorContext implements ActorContext, BehaviourContext {
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
  void unwatch(ActorRef actor) {
    actor.unwatch(self);
    system._flushTerminated(self, actor);
  }

  @override
  void forward(ActorRef target, Object? message) =>
      Sending.as(sender, () => target.tell(message));

  @override
  bool trapExits = false;

  BehaviourHandoff? _handoff;

  @override
  BehaviourHandoff? takeHandoff() {
    final handoff = _handoff;
    _handoff = null;
    return handoff;
  }

  @override
  void deliverFirst(Object? message) {
    final info = system._actorInfo[self.id];
    if (info == null || !identical(system._actors[self.id], self)) return;
    info.mailbox.enqueueFirst(Envelope(message, null));
  }

  @override
  Future<T> receive<T>({bool Function(T message)? where, Duration? timeout}) =>
      system._receive<T>(this, where, timeout);

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
