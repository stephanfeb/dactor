// lib/src/metrics/metrics.dart

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

/// A simple in-memory metrics collector for testing and basic monitoring.
class InMemoryMetricsCollector implements MetricsCollector {
  final _counters = <String, int>{};
  final _gauges = <String, double>{};
  final _timings = <String, List<Duration>>{};

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
    _timings.putIfAbsent(name, () => []).add(duration);
  }

  /// Gets the current value of a counter.
  int getCounter(String name) => _counters[name] ?? 0;

  /// Gets the current value of a gauge.
  double? getGauge(String name) => _gauges[name];

  /// Gets all recorded timings for a metric.
  List<Duration> getTimings(String name) => _timings[name] ?? [];

  /// Clears all stored metrics.
  void clear() {
    _counters.clear();
    _gauges.clear();
    _timings.clear();
  }
}
