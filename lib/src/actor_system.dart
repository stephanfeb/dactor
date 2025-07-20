import 'package:dactor/src/routing/pool.dart';
import 'ask_config.dart';

import 'actor.dart';
import 'metrics/metrics.dart';
import 'tracing/tracing.dart';
import 'logging/logging.dart';
import 'actor_ref.dart';
import 'local_actor_system.dart';
import 'supervision.dart';
import 'event_bus.dart';

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
  final MetricsCollector? metricsCollector;
  final TraceCollector? traceCollector;
  final LogCollector? logCollector;
  
  /// Configuration for ask pattern behavior including timeouts and retries.
  final AskConfig askConfig;

  ActorSystemConfig({
    this.metricsCollector,
    this.traceCollector,
    this.logCollector,
    AskConfig? askConfig,
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
