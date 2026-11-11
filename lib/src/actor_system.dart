import 'package:dactor/src/routing/pool.dart';
import 'package:dactor/src/ask_config.dart';
import 'package:dactor/src/actor.dart';
import 'package:dactor/src/metrics/metrics.dart';
import 'package:dactor/src/tracing/tracing.dart';
import 'package:dactor/src/logging/logging.dart';
import 'package:dactor/src/actor_ref.dart';
import 'package:dactor/src/local_actor_system.dart';
import 'package:dactor/src/supervision.dart';
import 'package:dactor/src/event_bus.dart';

/// A system for managing actors.
///
/// The actor system is the entry point for creating and managing actors.
abstract class ActorSystem {
  /// Creates a new actor system.
  static ActorSystem create([ActorSystemConfig? config]) {
    return LocalActorSystem(config);
  }

  /// Spawns a new actor.
  Future<ActorRef> spawn<T extends Actor>(
    String id,
    T Function() actorFactory, {
    SupervisionStrategy? supervision,
    Pool? pool,
  });

  /// Stops the specified actor.
  Future<void> stop(ActorRef actor);

  /// Retrieves an actor by its ID.
  ActorRef? getActor(String id);

  /// Shuts down the actor system.
  Future<void> shutdown();

  /// The metrics collector of the actor system.
  MetricsCollector get metrics;

  /// The trace collector of the actor system.
  TraceCollector get tracer;

  /// The log collector of the actor system.
  LogCollector get logger;

  /// The event bus of the actor system.
  EventBus get eventBus;

  /// The events of the actor system.
  Stream<EventBusEvent> get events;
}

/// The configuration for an actor system.
class ActorSystemConfig {
  /// Where metrics go. Defaults to [NoOpMetricsCollector]; pass an
  /// [InMemoryMetricsCollector] (bounded) or your own implementation to
  /// collect them.
  final MetricsCollector? metricsCollector;

  /// Where message traces go. Defaults to [NoOpTraceCollector]; pass an
  /// [InMemoryTraceCollector] (bounded) or your own implementation to
  /// collect them. Tracing records every message sent and processed, so
  /// enable it deliberately.
  final TraceCollector? traceCollector;

  /// Where log records go. Defaults to [ConsoleLogCollector].
  final LogCollector? logCollector;

  /// Configuration for ask pattern behavior including timeouts and retries.
  final AskConfig askConfig;

  /// Maximum size of the dead letter queue before oldest entries are evicted.
  final int deadLetterQueueMaxSize;

  /// The most messages the system dispatches in one event-loop turn before
  /// yielding so that timers and I/O can run. Defaults to 128.
  final int? maxMessagesPerTurn;

  /// The longest the system keeps dispatching in one event-loop turn before
  /// yielding. Defaults to 4 ms. A single handler that blocks for longer than
  /// this still holds the isolate; see [blockingHandlerThreshold].
  final Duration? maxTurnDuration;

  /// A handler that runs for longer than this before its first `await` is
  /// counted under the `actors.blocking_handler` metric, tagged with the
  /// actor's id. Defaults to 10 ms.
  final Duration? blockingHandlerThreshold;

  ActorSystemConfig({
    this.metricsCollector,
    this.traceCollector,
    this.logCollector,
    AskConfig? askConfig,
    this.deadLetterQueueMaxSize = 1000,
    this.maxMessagesPerTurn,
    this.maxTurnDuration,
    this.blockingHandlerThreshold,
  }) : askConfig = askConfig ?? AskConfig();

  /// Creates a development-friendly configuration with longer timeouts and more retries.
  factory ActorSystemConfig.development({
    MetricsCollector? metricsCollector,
    TraceCollector? traceCollector,
    LogCollector? logCollector,
  }) =>
      ActorSystemConfig(
        metricsCollector: metricsCollector,
        traceCollector: traceCollector,
        logCollector: logCollector,
        askConfig: AskConfig.development(),
      );

  /// Creates a production configuration with shorter timeouts and fewer retries.
  factory ActorSystemConfig.production({
    MetricsCollector? metricsCollector,
    TraceCollector? traceCollector,
    LogCollector? logCollector,
  }) =>
      ActorSystemConfig(
        metricsCollector: metricsCollector,
        traceCollector: traceCollector,
        logCollector: logCollector,
        askConfig: AskConfig.production(),
      );
}
