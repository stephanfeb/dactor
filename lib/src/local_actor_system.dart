import 'dart:async';
import 'dart:collection';

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
import 'package:dactor/src/supervisor_actor.dart';
import 'package:dactor/src/event_bus.dart';
import 'package:dactor/src/timer_scheduler.dart';
import 'package:dactor/src/dactor_timer_scheduler.dart';

class _ActorInfo {
  final Actor actor;
  final SupervisionStrategy? supervision;

  _ActorInfo(this.actor, this.supervision);
}

class LocalActorSystem implements ActorSystem {
  final _actors = <String, LocalActorRef>{};
  final _actorInfo = <String, _ActorInfo>{};
  final _factoriesById = <String, Function>{};
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
  bool _isProcessing = false;
  Completer<void> _pumpSignal = Completer<void>();

  LocalActorSystem([ActorSystemConfig? config])
      : metrics = config?.metricsCollector ?? InMemoryMetricsCollector(),
        tracer = config?.traceCollector ?? InMemoryTraceCollector(),
        logger = config?.logCollector ?? ConsoleLogCollector(),
        askConfig = config?.askConfig ?? AskConfig() {
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
  }) async {
    if (_isShutdown) {
      throw StateError('Actor system is shutdown');
    }
    if (_actors.containsKey(id)) {
      throw ArgumentError('Actor with id $id already exists');
    }

    final actor = actorFactory();
    final mailbox = Mailbox(id, scheduleMailbox, onGauge: metrics.gauge);
    final actorRef = LocalActorRef(id, mailbox, deadLetterQueue, tracer, askConfig);

    _actors[id] = actorRef;
    _actorInfo[id] = _ActorInfo(actor, supervision);
    _factoriesById[id] = actorFactory;

    await _runActor(actor, actorRef);

    return (ref: actorRef, actor: actor);
  }

  Future<void> _runActor(Actor actor, LocalActorRef actorRef) async {
    final context = _ActorContext(actorRef, this);
    actor.context = context;
    await actor.preStart();
    metrics.increment('actors.spawned');
    metrics.gauge('actors.active', _actors.length.toDouble());
  }

  void _messagePump() async {
    _isProcessing = true;
    while (!_isShutdown) {
      if (_activeMailboxes.isNotEmpty) {
        final mailbox = _activeMailboxes.removeFirst();
        _scheduledMailboxes.remove(mailbox);

        if (mailbox.isDisposed) {
          continue;
        }

        final message = mailbox.dequeue();
        final info = _actorInfo[mailbox.actorId];

        if (message != null && info != null) {
          metrics.increment('messages.processed');
          final actor = info.actor;
          final actorRef = _actors[mailbox.actorId]!;

          _processingActors.add(mailbox.actorId);
          _processMessageAsync(actor, actorRef, message, mailbox);
        }
      } else {
        await _waitForWork();
      }
    }
    _isProcessing = false;
  }

  /// Processes a single message asynchronously without blocking the message pump.
  /// This allows actors to use natural await syntax (like await ask()) without
  /// causing deadlocks in the single-threaded message pump.
  void _processMessageAsync(Actor actor, LocalActorRef actorRef, Message message, Mailbox mailbox) {
    final stopwatch = Stopwatch()..start();

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
        final supervisorId = actorRef.id.contains('/')
            ? actorRef.id.substring(0, actorRef.id.lastIndexOf('/'))
            : null;
        if (supervisorId != null && _actorInfo.containsKey(supervisorId)) {
          final supervisor =
              _actorInfo[supervisorId]!.actor as SupervisorActor;
          await supervisor.onChildFailure(actorRef, e, s);
        } else {
          stop(actorRef);
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

  Future<void> _restartActor(String id) async {
    final actorRef = _actors[id];
    final info = _actorInfo[id];
    if (actorRef != null && info != null) {
      metrics.increment('actors.restarted', tags: {'actorId': id});
      final actorFactory = _factoriesById[id];
      if (actorFactory != null) {
        final supervision = info.supervision;
        await stop(actorRef);
        await spawn(id, actorFactory as Actor Function(),
            supervision: supervision);
      }
    }
  }

  @override
  Future<void> stop(ActorRef actor) async {
    if (_isShutdown) {
      return;
    }
    final actorRef = _actors[actor.id];
    if (actorRef is LocalActorRef) {
      final info = _actorInfo[actor.id];
      if (info != null) {
        final timerScheduler = info.actor.context.timers;
        if (timerScheduler is DactorTimerScheduler) {
          timerScheduler.dispose();
        }

        info.actor.postStop();
      }

      _eventBus.cleanup(actorRef);

      actorRef.stop();
      _actors.remove(actor.id);
      _actorInfo.remove(actor.id);
      _factoriesById.remove(actor.id);
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
    for (final actorRef in List.from(_actors.values)) {
      await stop(actorRef);
    }
    _actors.clear();
    _actorInfo.clear();
    _factoriesById.clear();
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
