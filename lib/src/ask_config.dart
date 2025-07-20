import 'dart:async';
import 'dart:math' as math;

/// Configuration for the ask pattern (request-response) behavior.
class AskConfig {
  /// Default timeout for ask operations when no timeout is specified.
  final Duration defaultTimeout;

  /// Maximum number of retry attempts for failed ask operations.
  final int maxRetries;

  /// Base duration for exponential backoff between retries.
  final Duration retryBackoffBase;

  /// Multiplier for exponential backoff calculation.
  final double retryBackoffMultiplier;

  /// Maximum backoff duration to prevent excessively long waits.
  final Duration maxBackoffDuration;

  /// Whether to enable automatic retries for ask operations.
  final bool enableRetries;

  /// Types of errors that should trigger a retry (by default, only TimeoutException).
  final Set<Type> retryableErrorTypes;

  AskConfig({
    this.defaultTimeout = const Duration(seconds: 5),
    this.maxRetries = 3,
    this.retryBackoffBase = const Duration(milliseconds: 100),
    this.retryBackoffMultiplier = 2.0,
    this.maxBackoffDuration = const Duration(seconds: 10),
    this.enableRetries = true,
    Set<Type>? retryableErrorTypes,
  }) : retryableErrorTypes = retryableErrorTypes ?? {TimeoutException};

  /// Creates a development-friendly configuration with longer timeouts.
  factory AskConfig.development() => AskConfig(
        defaultTimeout: Duration(seconds: 30),
        maxRetries: 5,
        retryBackoffBase: Duration(milliseconds: 200),
      );

  /// Creates a production configuration with shorter timeouts and faster retries.
  factory AskConfig.production() => AskConfig(
        defaultTimeout: Duration(seconds: 3),
        maxRetries: 2,
        retryBackoffBase: Duration(milliseconds: 50),
      );

  /// Creates a configuration with retries disabled.
  factory AskConfig.noRetries() => AskConfig(
        enableRetries: false,
        maxRetries: 0,
      );

  /// Calculates the backoff duration for a given retry attempt.
  Duration calculateBackoff(int retryAttempt) {
    if (retryAttempt <= 0) return Duration.zero;

    final backoff = Duration(
      milliseconds: (retryBackoffBase.inMilliseconds *
              math.pow(retryBackoffMultiplier, retryAttempt - 1))
          .round(),
    );

    return backoff > maxBackoffDuration ? maxBackoffDuration : backoff;
  }

  /// Checks if an error type is retryable according to this configuration.
  bool isRetryableError(Object error) {
    return retryableErrorTypes.any((type) => error.runtimeType == type);
  }

  @override
  String toString() {
    return 'AskConfig{'
        'defaultTimeout: $defaultTimeout, '
        'maxRetries: $maxRetries, '
        'enableRetries: $enableRetries'
        '}';
  }
} 