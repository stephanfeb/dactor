import '../actor_ref.dart';

/// The different log levels supported by the logging system.
enum LogLevel {
  debug,
  info,
  warning,
  error,
}

/// Represents a single log entry.
class LogRecord {
  /// The level of the log entry.
  final LogLevel level;

  /// The message of the log entry.
  final String message;

  /// The time the log entry was created.
  final DateTime timestamp;

  /// The actor that created the log entry.
  final ActorRef? actor;

  LogRecord(this.level, this.message, {this.actor}) : timestamp = DateTime.now();

  @override
  String toString() {
    final actorPath = actor?.id.toString() ?? 'System';
    return '[${timestamp.toIso8601String()}] [$level] [$actorPath] $message';
  }
}

/// An interface for collecting log records.
abstract class LogCollector {
  /// Records a single log entry.
  void record(LogRecord record);
}

/// An implementation of [LogCollector] that prints log records to the console.
class ConsoleLogCollector implements LogCollector {
  @override
  void record(LogRecord record) {
    print(record.toString());
  }
}
