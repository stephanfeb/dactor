import 'dart:async';

import 'actor_ref.dart';
import 'local_message.dart';
import 'timer_scheduler.dart';

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
  bool _disposed = false;

  DactorTimerScheduler(this._self);

  @override
  void startSingleTimer(String key, dynamic message, Duration delay) {
    if (_disposed) return;
    
    _cancelExisting(key);
    
    final timer = Timer(delay, () {
      if (!_disposed) {
        _self.tell(LocalMessage(payload: message));
        _timers.remove(key);
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
    _scheduleFixedDelay(key, message, delay);
  }

  @override
  void startTimerAtFixedRate(String key, dynamic message, Duration interval) {
    if (_disposed) return;
    
    _cancelExisting(key);
    
    final timer = Timer.periodic(interval, (_) {
      if (!_disposed && _timers.containsKey(key)) {
        _self.tell(LocalMessage(payload: message));
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
    final entry = _timers.remove(key);
    entry?.timer.cancel();
  }

  @override
  void cancelAll() {
    for (final entry in _timers.values) {
      entry.timer.cancel();
    }
    _timers.clear();
  }

  @override
  bool isTimerActive(String key) {
    final entry = _timers[key];
    return entry != null && entry.timer.isActive;
  }

  @override
  List<String> get activeTimers {
    return _timers.keys
        .where((key) => _timers[key]!.timer.isActive)
        .toList();
  }

  /// Internal method to schedule fixed delay timers
  void _scheduleFixedDelay(String key, dynamic message, Duration delay) {
    final timer = Timer(delay, () {
      if (!_disposed && _timers.containsKey(key)) {
        _self.tell(LocalMessage(payload: message));
        // Schedule the next execution after this one completes
        _scheduleFixedDelay(key, message, delay);
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

  /// Internal method to cancel existing timer with the same key
  void _cancelExisting(String key) {
    final existing = _timers.remove(key);
    existing?.timer.cancel();
  }

  /// Dispose all timers - called when actor is stopped
  void dispose() {
    _disposed = true;
    cancelAll();
  }

  /// Check if the scheduler has been disposed
  bool get isDisposed => _disposed;
} 