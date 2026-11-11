import 'dart:async';
import 'dart:collection';

import 'package:meta/meta.dart';

import 'package:dactor/src/actor.dart';
import 'package:dactor/src/actor_ref.dart';
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
import 'package:dactor/src/timer_scheduler.dart';
import 'package:dactor/src/dactor_timer_scheduler.dart';

/// Everything the system knows about one actor *cell*: the identity that
/// survives restarts (mailbox, factory, strategy) plus the current [actor]
/// incarnation, which a restart replaces.
class _ActorInfo {
  Actor actor;
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

  _ActorInfo(this.actor, this.factory, this.supervision, this.mailbox,
      {this.parentId});
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

  @override
  Future<ActorRef> spawn<T extends Actor>(
    String id,
    T Function() actorFactory, {
    SupervisionStrategy? supervision,
    Pool? pool,
  }) async {
    if (pool != null) {
      return (await spawnAndGetActor(
        id,
        () => RouterActor(pool, actorFactory),
        supervision: supervision,
      ))
          .ref;
    }
    return (await spawnAndGetActor(id, actorFactory, supervision: supervision))
        .ref;
  }

  Future<({ActorRef ref, Actor actor})> spawnAndGetActor<T extends Actor>(
    String id,
    T Function() actorFactory, {
    SupervisionStrategy? supervision,
  }) {
    return _spawn(id, actorFactory, supervision: supervision);
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
  }) async {
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
    final info = _ActorInfo(actor, actorFactory, supervision, mailbox,
        parentId: parentId);

    _actors[id] = actorRef;
    _actorInfo[id] = info;

    try {
      await _startIncarnation(info, actorRef);
    } catch (_) {
      // preStart failed: the actor never existed. Free the id and release
      // whatever was registered, without running postStop on an actor that
      // did not finish initialising.
      metrics.increment('actors.start_failed', tags: {'actorId': id});
      if (identical(_actorInfo[id], info)) {
        await _stopActor(actorRef);
      }
      rethrow;
    }
    metrics.increment('actors.spawned');
    metrics.gauge('actors.active', _actors.length.toDouble());

    return (ref: actorRef, actor: actor);
  }

  /// Wires a fresh context into [info.actor], runs its `preStart`, and only
  /// then opens the mailbox for processing.
  Future<void> _startIncarnation(
      _ActorInfo info, LocalActorRef actorRef) async {
    final actor = info.actor;
    actor.context = _ActorContext(actorRef, this);
    await actor.preStart();
    if (!_isCurrent(info, actor)) {
      // Stopped or replaced while preStart was still running. This
      // incarnation did start, so it is owed its postStop.
      _disposeTimers(actor);
      _runPostStop(actor, actorRef.id);
      return;
    }
    info.started = true;
    if (!info.mailbox.isEmpty) {
      scheduleMailbox(info.mailbox);
    }
  }

  /// True while [actor] is the running incarnation of the cell [info].
  bool _isCurrent(_ActorInfo info, Actor actor) =>
      identical(_actorInfo[actor.context.self.id], info) &&
      identical(info.actor, actor);

  void _disposeTimers(Actor actor) {
    final timers = actor.context.timers;
    if (timers is DactorTimerScheduler) {
      timers.dispose();
    }
  }

  /// Runs `postStop`, containing anything it throws so that one bad hook
  /// cannot abort a stop, a restart or a shutdown.
  void _runPostStop(Actor actor, String id) {
    try {
      actor.postStop();
    } catch (e) {
      metrics.increment('actors.post_stop_failed', tags: {'actorId': id});
      logger.record(LogRecord(LogLevel.error, 'postStop of $id threw: $e'));
    }
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
      if (info == null || !info.started) {
        // Not (yet) runnable; _startIncarnation reschedules once ready.
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
      _processMessageAsync(info, actorRef, message);
      final after = _turnClock.elapsedMicroseconds;

      // _processMessageAsync returns at the handler's first suspension, so
      // this is the time the handler held the isolate without yielding.
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

  /// Processes a single message asynchronously without blocking the message pump.
  /// This allows actors to use natural await syntax (like await ask()) without
  /// causing deadlocks in the single-threaded message pump.
  void _processMessageAsync(
      _ActorInfo info, LocalActorRef actorRef, Message message) {
    final stopwatch = Stopwatch()..start();
    // Pin the incarnation that handles this message; a restart during the
    // handler must not redirect the bookkeeping below to the replacement.
    final actor = info.actor;
    final mailbox = info.mailbox;

    () async {
      try {
        if (message is LocalMessage) {
          (actor.context as _ActorContext).sender = message.sender;
          tracer.record(TraceEvent(
              message.correlationId, 'processed', actorRef, message.payload));
          await actor.onMessage(message.payload);
        } else {
          await actor.onMessage(message);
        }
      } catch (e, s) {
        metrics.increment('actors.failed');
        final parentId = info.parentId;
        final parent = parentId == null ? null : _actorInfo[parentId]?.actor;
        try {
          if (parent is Supervisor) {
            await parent.onChildFailure(actorRef, e, s);
          } else {
            // Unsupervised (or the supervisor is gone): stop the actor.
            await stop(actorRef);
          }
        } catch (supervisionError) {
          // Supervision itself failed (for example the replacement's
          // preStart threw). This closure is not awaited by anyone, so an
          // escaping error would be an unhandled zone error; contain it and
          // give up on the child.
          metrics.increment('actors.supervision_failed',
              tags: {'actorId': actorRef.id});
          logger.record(LogRecord(
              LogLevel.error,
              'Supervision of ${actorRef.id} failed after $e: '
              '$supervisionError',
              actor: actorRef));
          await stop(actorRef);
        }
      } finally {
        stopwatch.stop();
        metrics.timing('messages.processing_time', stopwatch.elapsed);
        (actor.context as _ActorContext).sender = null;

        _processingActors.remove(mailbox.actorId);

        if (!mailbox.isEmpty && !mailbox.isDisposed) {
          scheduleMailbox(mailbox);
        }
      }
    }();
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

  /// Restarts the actor with [id] in place.
  ///
  /// The [LocalActorRef], its mailbox (including every pending message),
  /// watchers and event-bus subscriptions are kept. Only the [Actor] instance
  /// is replaced: `postStop` runs on the old incarnation, its timers are
  /// cancelled, and `preStart` runs on the new one before any further message
  /// is delivered. The message that triggered the failure is not redelivered.
  Future<void> _restartActor(String id) async {
    if (_isShutdown) {
      return;
    }
    final actorRef = _actors[id];
    final info = _actorInfo[id];
    if (actorRef == null || info == null) {
      return;
    }
    metrics.increment('actors.restarted', tags: {'actorId': id});

    final wasStarted = info.started;
    info.started = false;
    final old = info.actor;
    _disposeTimers(old);
    if (wasStarted) {
      // An incarnation still inside preStart gets its postStop from
      // _startIncarnation, once it notices it has been replaced.
      _runPostStop(old, id);
    }

    info.actor = info.factory();
    try {
      await _startIncarnation(info, actorRef);
    } catch (e) {
      // The replacement could not initialise; there is nothing left to run.
      if (identical(_actorInfo[id], info)) {
        await _stopActor(actorRef);
      }
      rethrow;
    }
  }

  @override
  Future<void> stop(ActorRef actor) async {
    if (_isShutdown) {
      return;
    }
    await _stopActor(actor);
  }

  /// Stops [actor] regardless of the shutdown flag.
  ///
  /// [stop] refuses work once shutdown has begun, but [shutdown] itself must
  /// still be able to tear every actor down, so it calls this directly.
  Future<void> _stopActor(ActorRef actor) async {
    final actorRef = _actors[actor.id];
    if (actorRef is LocalActorRef) {
      final info = _actorInfo[actor.id];
      if (info != null) {
        _disposeTimers(info.actor);
        // An actor whose preStart has not completed has nothing to release
        // yet; if preStart is still running it gets postStop when it ends.
        if (info.started) {
          info.started = false;
          _runPostStop(info.actor, actor.id);
        }
      }

      _eventBus.cleanup(actorRef);

      actorRef.stop();
      _actors.remove(actor.id);
      _actorInfo.remove(actor.id);
      metrics.gauge('actors.active', _actors.length.toDouble());
      metrics.increment('actors.stopped');
    } else {
      metrics.increment('actors.stop_failed');
      deadLetterQueue.enqueue(
          LocalMessage(payload: 'Message to non-existent actor: ${actor.id}'));
    }
  }

  @override
  ActorRef? getActor(String id) {
    if (_isShutdown) {
      return null;
    }
    return _actors[id];
  }

  @override
  Future<void> shutdown() async {
    if (_isShutdown) {
      return;
    }
    _isShutdown = true;
    _wakeUpPump();
    metrics.increment('system.shutdown');
    // Stop in reverse spawn order so children (spawned after their parents)
    // are torn down before the actors that created them.
    for (final actorRef in List<LocalActorRef>.of(_actors.values).reversed) {
      await _stopActor(actorRef);
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
  Future<void> restart(ActorRef child) {
    return system._restartActor(child.id);
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
