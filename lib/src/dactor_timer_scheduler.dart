import 'dart:async';

import 'package:meta/meta.dart';

import 'actor_ref.dart';
import 'sending.dart';
import 'timer_scheduler.dart';

/// A timer's message on its way to the actor.
///
/// The actor is handed [message] only if the timer that sent it has not been
/// cancelled or restarted since; otherwise the tick is dropped. This is what
/// keeps [TimerScheduler.cancel]'s promise for a tick already queued.
@internal
final class TimerTick {
  final DactorTimerScheduler _scheduler;
  final String _key;
  final int _generation;
  final Object? message;

  TimerTick._(this._scheduler, this._key, this._generation, this.message);

  /// Whether the timer that sent this tick is still the one under its key.
  bool get isCurrent => _scheduler._isCurrent(_key, _generation);
}

/// Internal timer entry to track timer state
class _TimerEntry {
  final Timer timer;
  final String key;
  final dynamic message;
  final Duration interval;
  final bool isRepeating;
  final bool isFixedRate;

  _TimerEntry({
    required this.timer,
    required this.key,
    required this.message,
    required this.interval,
    required this.isRepeating,
    required this.isFixedRate,
  });
}

/// Concrete implementation of TimerScheduler for Dactor actors.
///
/// This implementation uses Dart's Timer class to schedule message delivery
/// to actors and automatically handles cleanup when the actor is stopped.
class DactorTimerScheduler implements TimerScheduler {
  final ActorRef _self;
  final Map<String, _TimerEntry> _timers = {};

  /// The generation of the timer under each key. Starting, restarting or
  /// cancelling a key moves it on, which makes its queued ticks stale.
  final Map<String, int> _generations = {};
  bool _disposed = false;

  DactorTimerScheduler(this._self);

  int _nextGeneration(String key) =>
      _generations[key] = (_generations[key] ?? 0) + 1;

  bool _isCurrent(String key, int generation) =>
      !_disposed && _generations[key] == generation;

  void _send(String key, int generation, Object? message) {
    Sending.as(
        null, () => _self.tell(TimerTick._(this, key, generation, message)));
  }

  @override
  void startSingleTimer(String key, dynamic message, Duration delay) {
    if (_disposed) return;

    _cancelExisting(key);
    final generation = _nextGeneration(key);

    final timer = Timer(delay, () {
      if (!_disposed) {
        _timers.remove(key);
        _send(key, generation, message);
      }
    });

    _timers[key] = _TimerEntry(
      timer: timer,
      key: key,
      message: message,
      interval: delay,
      isRepeating: false,
      isFixedRate: false,
    );
  }

  @override
  void startTimerWithFixedDelay(String key, dynamic message, Duration delay) {
    if (_disposed) return;

    _cancelExisting(key);
    _scheduleFixedDelay(key, _nextGeneration(key), message, delay);
  }

  @override
  void startTimerAtFixedRate(String key, dynamic message, Duration interval) {
    if (_disposed) return;

    _cancelExisting(key);
    final generation = _nextGeneration(key);

    final timer = Timer.periodic(interval, (_) {
      if (!_disposed && _timers.containsKey(key)) {
        _send(key, generation, message);
      }
    });

    _timers[key] = _TimerEntry(
      timer: timer,
      key: key,
      message: message,
      interval: interval,
      isRepeating: true,
      isFixedRate: true,
    );
  }

  @override
  void cancel(String key) {
    _cancelExisting(key);
  }

  @override
  void cancelAll() {
    for (final entry in _timers.values) {
      entry.timer.cancel();
    }
    _timers.clear();
    for (final key in _generations.keys) {
      _generations[key] = _generations[key]! + 1;
    }
  }

  @override
  bool isTimerActive(String key) {
    final entry = _timers[key];
    return entry != null && entry.timer.isActive;
  }

  @override
  List<String> get activeTimers {
    return _timers.keys.where((key) => _timers[key]!.timer.isActive).toList();
  }

  /// Internal method to schedule fixed delay timers
  void _scheduleFixedDelay(
      String key, int generation, dynamic message, Duration delay) {
    final timer = Timer(delay, () {
      if (!_disposed && _timers.containsKey(key)) {
        _send(key, generation, message);
        // Schedule the next execution after this one completes
        _scheduleFixedDelay(key, generation, message, delay);
      }
    });

    _timers[key] = _TimerEntry(
      timer: timer,
      key: key,
      message: message,
      interval: delay,
      isRepeating: true,
      isFixedRate: false,
    );
  }

  /// Cancels the timer under [key], if any, and makes its queued ticks
  /// stale.
  void _cancelExisting(String key) {
    final existing = _timers.remove(key);
    existing?.timer.cancel();
    if (_generations.containsKey(key)) _nextGeneration(key);
  }

  /// Dispose all timers - called when actor is stopped
  void dispose() {
    _disposed = true;
    cancelAll();
  }

  /// Check if the scheduler has been disposed
  bool get isDisposed => _disposed;
}
