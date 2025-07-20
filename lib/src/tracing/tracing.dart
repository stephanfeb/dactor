import '../actor_ref.dart';

/// An event in a message's lifecycle.
class TraceEvent {
  final String correlationId;
  final String event;
  final ActorRef actor;
  final dynamic message;
  final DateTime timestamp;

  TraceEvent(
    this.correlationId,
    this.event,
    this.actor,
    this.message,
  ) : timestamp = DateTime.now();
}

/// A collector for trace events.
abstract class TraceCollector {
  /// Records a trace event.
  void record(TraceEvent event);
}

/// A trace collector that stores traces in memory.
class InMemoryTraceCollector implements TraceCollector {
  final _traces = <String, List<TraceEvent>>{};

  @override
  void record(TraceEvent event) {
    _traces.putIfAbsent(event.correlationId, () => []).add(event);
  }

  /// Returns all traces.
  Map<String, List<TraceEvent>> get traces => _traces;
}
