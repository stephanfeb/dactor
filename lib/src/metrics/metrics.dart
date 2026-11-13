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
/// Counters and gauges are kept per name and, for those recorded with tags,
/// also per name and tags: `getCounter('dead_letters')` is the total, and
/// `getGauge('mailbox.size', tags: {'actorId': 'a'})` is one actor's mailbox.
/// Timings are kept per name in a bounded window of the most recent
/// [maxTimings] samples so that a long-running system cannot grow without
/// limit. Tagged series are not bounded: there is one per distinct set of
/// tags, so with per-actor tags one per actor ever seen. This collector is
/// meant for tests and local debugging.
class InMemoryMetricsCollector implements MetricsCollector {
  final _counters = <String, int>{};
  final _gauges = <String, double>{};
  final _taggedCounters = <String, int>{};
  final _taggedGauges = <String, double>{};
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
    if (tags != null && tags.isNotEmpty) {
      _taggedCounters.update(_series(name, tags), (value) => value + count,
          ifAbsent: () => count);
    }
  }

  @override
  void decrement(String name, {int count = 1, Map<String, String>? tags}) {
    increment(name, count: -count, tags: tags);
  }

  @override
  void gauge(String name, double value, {Map<String, String>? tags}) {
    _gauges[name] = value;
    if (tags != null && tags.isNotEmpty) {
      _taggedGauges[_series(name, tags)] = value;
    }
  }

  /// The key of one tagged series: the name and the tags, sorted by key.
  static String _series(String name, Map<String, String> tags) {
    final keys = tags.keys.toList()..sort();
    return '$name{${keys.map((k) => '$k=${tags[k]}').join(',')}}';
  }

  @override
  void timing(String name, Duration duration, {Map<String, String>? tags}) {
    final samples = _timings.putIfAbsent(name, Queue.new);
    samples.add(duration);
    if (samples.length > maxTimings) {
      samples.removeFirst();
    }
  }

  /// Gets the current value of a counter: the total over all tags, or with
  /// [tags], only what was recorded with exactly those tags.
  int getCounter(String name, {Map<String, String>? tags}) =>
      (tags == null || tags.isEmpty
          ? _counters[name]
          : _taggedCounters[_series(name, tags)]) ??
      0;

  /// Gets the current value of a gauge: the last value recorded under
  /// [name] whatever its tags, or with [tags], the last recorded with exactly
  /// those tags.
  double? getGauge(String name, {Map<String, String>? tags}) =>
      tags == null || tags.isEmpty
          ? _gauges[name]
          : _taggedGauges[_series(name, tags)];

  /// Gets the retained timing samples for a metric, oldest first.
  List<Duration> getTimings(String name) =>
      List.unmodifiable(_timings[name] ?? const <Duration>[]);

  /// Clears all stored metrics.
  void clear() {
    _counters.clear();
    _gauges.clear();
    _taggedCounters.clear();
    _taggedGauges.clear();
    _timings.clear();
  }
}
