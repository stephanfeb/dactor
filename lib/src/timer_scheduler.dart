/// A scheduler for managing timers within an actor.
/// 
/// TimerScheduler provides methods to schedule messages to be sent to an actor
/// at specific times or intervals. Timers are bound to the actor's lifecycle
/// and are automatically cancelled when the actor is stopped or restarted.
/// 
/// Each timer is identified by a key, and starting a new timer with an existing
/// key will cancel the previous timer with that key.
abstract class TimerScheduler {
  /// Starts a single-shot timer that sends [message] to the actor after [delay].
  /// 
  /// If a timer with the same [key] already exists, it will be cancelled before
  /// starting the new timer.
  /// 
  /// Example:
  /// ```dart
  /// // Send 'timeout' message after 30 seconds
  /// context.timers.startSingleTimer('timeout', 'timeout', Duration(seconds: 30));
  /// ```
  void startSingleTimer(String key, dynamic message, Duration delay);

  /// Starts a periodic timer that sends [message] with fixed delay between executions.
  /// 
  /// The delay between subsequent executions will always be (at least) the given [delay].
  /// It will not compensate if message processing takes longer than expected.
  /// 
  /// If a timer with the same [key] already exists, it will be cancelled before
  /// starting the new timer.
  /// 
  /// Example:
  /// ```dart
  /// // Send 'cleanup' message every 5 minutes with fixed delay
  /// context.timers.startTimerWithFixedDelay('cleanup', 'cleanup', Duration(minutes: 5));
  /// ```
  void startTimerWithFixedDelay(String key, dynamic message, Duration delay);

  /// Starts a periodic timer that sends [message] with fixed rate.
  /// 
  /// The frequency of execution over time will meet the given [interval].
  /// If execution takes longer than the interval, subsequent executions will
  /// be scheduled immediately to catch up.
  /// 
  /// If a timer with the same [key] already exists, it will be cancelled before
  /// starting the new timer.
  /// 
  /// Example:
  /// ```dart
  /// // Send 'heartbeat' message every 30 seconds at fixed rate
  /// context.timers.startTimerAtFixedRate('heartbeat', 'tick', Duration(seconds: 30));
  /// ```
  void startTimerAtFixedRate(String key, dynamic message, Duration interval);

  /// Cancels the timer with the given [key].
  /// 
  /// If no timer with the given key exists, this operation does nothing.
  /// It is guaranteed that no message from the cancelled timer will be
  /// received by the actor after this method returns.
  void cancel(String key);

  /// Cancels all active timers for this actor.
  /// 
  /// After this method returns, no timer messages will be received by the actor.
  void cancelAll();

  /// Returns true if a timer with the given [key] is currently active.
  bool isTimerActive(String key);

  /// Returns a list of all active timer keys.
  List<String> get activeTimers;
} 