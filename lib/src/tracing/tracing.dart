import 'dart:collection';

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

/// A collector that discards everything. This is the default for a
/// [LocalActorSystem] created without an explicit [TraceCollector].
class NoOpTraceCollector implements TraceCollector {
  const NoOpTraceCollector();

  @override
  void record(TraceEvent event) {}
}

/// A trace collector that stores traces in memory, grouped by correlation id.
///
/// At most [maxEvents] events are retained. When the limit is exceeded the
/// events of the oldest correlation ids are dropped first, so a complete
/// recent trace is always preferred over fragments of old ones. Note that a
/// retained [TraceEvent] holds a reference to the message payload.
class InMemoryTraceCollector implements TraceCollector {
  // Literal maps are insertion-ordered, which gives us oldest-first eviction.
  final _traces = <String, List<TraceEvent>>{};
  int _eventCount = 0;

  /// Maximum number of [TraceEvent]s retained across all correlation ids.
  final int maxEvents;

  InMemoryTraceCollector({this.maxEvents = 10000}) {
    if (maxEvents < 1) {
      throw ArgumentError.value(maxEvents, 'maxEvents', 'must be >= 1');
    }
  }

  @override
  void record(TraceEvent event) {
    _traces.putIfAbsent(event.correlationId, () => []).add(event);
    _eventCount++;
    while (_eventCount > maxEvents && _traces.isNotEmpty) {
      final oldestId = _traces.keys.first;
      _eventCount -= _traces.remove(oldestId)!.length;
    }
  }

  /// Returns all retained traces, keyed by correlation id.
  Map<String, List<TraceEvent>> get traces => UnmodifiableMapView(_traces);

  /// Number of events currently retained.
  int get eventCount => _eventCount;

  /// Drops all retained traces.
  void clear() {
    _traces.clear();
    _eventCount = 0;
  }
}
