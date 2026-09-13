// lib/src/metrics/metrics.dart

import 'dart:collection';

/// A generic interface for a metrics collector.
///
/// This can be implemented to interface with different monitoring systems
/// like Prometheus, StatsD, or a simple in-memory store.
abstract class MetricsCollector {
  /// Increments a counter by a given value.
  void increment(String name, {int count = 1, Map<String, String>? tags});

  /// Decrements a counter by a given value.
  void decrement(String name, {int count = 1, Map<String, String>? tags});

  /// Records a gauge value.
  void gauge(String name, double value, {Map<String, String>? tags});

  /// Records a timing value.
  void timing(String name, Duration duration, {Map<String, String>? tags});
}

/// A collector that discards everything. This is the default for a
/// [LocalActorSystem] created without an explicit [MetricsCollector].
class NoOpMetricsCollector implements MetricsCollector {
  const NoOpMetricsCollector();

  @override
  void increment(String name, {int count = 1, Map<String, String>? tags}) {}

  @override
  void decrement(String name, {int count = 1, Map<String, String>? tags}) {}

  @override
  void gauge(String name, double value, {Map<String, String>? tags}) {}

  @override
  void timing(String name, Duration duration, {Map<String, String>? tags}) {}
}

/// A simple in-memory metrics collector for testing and basic monitoring.
///
/// Counters and gauges are one value per name. Timings are kept per name in a
/// bounded window of the most recent [maxTimings] samples so that a
/// long-running system cannot grow without limit.
class InMemoryMetricsCollector implements MetricsCollector {
  final _counters = <String, int>{};
  final _gauges = <String, double>{};
  final _timings = <String, Queue<Duration>>{};

  /// Maximum number of timing samples retained per metric name.
  final int maxTimings;

  InMemoryMetricsCollector({this.maxTimings = 10000}) {
    if (maxTimings < 1) {
      throw ArgumentError.value(maxTimings, 'maxTimings', 'must be >= 1');
    }
  }

  @override
  void increment(String name, {int count = 1, Map<String, String>? tags}) {
    _counters.update(name, (value) => value + count, ifAbsent: () => count);
  }

  @override
  void decrement(String name, {int count = 1, Map<String, String>? tags}) {
    _counters.update(name, (value) => value - count, ifAbsent: () => -count);
  }

  @override
  void gauge(String name, double value, {Map<String, String>? tags}) {
    _gauges[name] = value;
  }

  @override
  void timing(String name, Duration duration, {Map<String, String>? tags}) {
    final samples = _timings.putIfAbsent(name, Queue.new);
    samples.add(duration);
    if (samples.length > maxTimings) {
      samples.removeFirst();
    }
  }

  /// Gets the current value of a counter.
  int getCounter(String name) => _counters[name] ?? 0;

  /// Gets the current value of a gauge.
  double? getGauge(String name) => _gauges[name];

  /// Gets the retained timing samples for a metric, oldest first.
  List<Duration> getTimings(String name) =>
      List.unmodifiable(_timings[name] ?? const <Duration>[]);

  /// Clears all stored metrics.
  void clear() {
    _counters.clear();
    _gauges.clear();
    _timings.clear();
  }
}
