import 'dart:async';

import 'package:meta/meta.dart';

import 'package:dactor/src/actor_ref.dart';
import 'package:dactor/src/dactor_timer_scheduler.dart';
import 'package:dactor/src/dead_letter_queue.dart';
import 'package:dactor/src/exit_reason.dart';
import 'package:dactor/src/mailbox.dart';
import 'package:dactor/src/local_message.dart';
import 'package:dactor/src/sending.dart';
import 'package:dactor/src/tracing/tracing.dart';
import 'package:dactor/src/ask_config.dart';
import 'package:dactor/src/system_messages.dart';

/// The `ActorRef` of an actor in a [LocalActorSystem]. Get one from `spawn`
/// rather than constructing it.
// Never copied into another isolate by accident: a message or closure that
// holds one fails to send instead.
@pragma('vm:isolate-unsendable')
class LocalActorRef implements ActorRef {
  @override
  final String id;
  final Mailbox _mailbox;
  final DeadLetterQueue _deadLetterQueue;
  final TraceCollector _tracer;
  final AskConfig _askConfig;

  /// A set: watching twice still means one `Terminated`.
  final _watchers = <ActorRef>{};
  bool _isAlive = true;
  static int _asks = 0;

  /// False for a [NoOpTraceCollector], so that no trace event is built for
  /// nothing.
  final bool _tracing;

  @internal
  LocalActorRef(this.id, this._mailbox, this._deadLetterQueue, this._tracer,
      this._askConfig)
      : _tracing = _tracer is! NoOpTraceCollector;

  @override
  bool get isAlive => _isAlive;

  /// Set on a pool's router: picks the worker a message goes to directly,
  /// or returns null to queue it for the router as usual.
  @internal
  ActorRef? Function(Object? message)? route;

  @override
  void tell(Object? message) {
    final payload = unwrapLegacy(message);
    final sender = Sending.sender;
    if ((payload is Terminated || payload is ExitSignal) && !Sending.isSystem) {
      // Only the runtime reports endings; anyone else's is a forgery.
      _deadLetterQueue.enqueue(DeadLetter(payload, sender, this));
      return;
    }
    if (_isAlive) {
      final route = this.route;
      // A timer's tick belongs to the actor that set the timer.
      if (route != null && !Sending.isSystem && payload is! TimerTick) {
        // Still inside the caller's send, so the worker sees the same sender.
        final target = route(payload);
        if (target != null) return target.tell(payload);
      }
      final envelope = Envelope(payload, sender);
      if (_tracing) {
        _tracer.record(TraceEvent(envelope.traceId, 'sent', this, payload));
      }
      _mailbox.enqueue(envelope, limited: !Sending.isSystem);
    } else {
      _deadLetterQueue.enqueue(DeadLetter(payload, sender, this));
    }
  }

  /// Puts [envelope] back in the mailbox as it is, for a simulation that
  /// delayed it.
  @internal
  void redeliver(Envelope envelope) {
    if (_isAlive) {
      // It was let in once already.
      _mailbox.enqueue(envelope, limited: false);
    } else {
      _deadLetterQueue
          .enqueue(DeadLetter(envelope.payload, envelope.sender, this));
    }
  }

  @override
  Future<T> ask<T>(Object? message, [Duration? timeout]) {
    return askWithRetry<T>(message, timeout: timeout);
  }

  /// Enhanced ask method with configurable retry logic and better error handling.
  Future<T> askWithRetry<T>(
    Object? message, {
    Duration? timeout,
    int? maxRetries,
    bool? enableRetries,
  }) async {
    if (!_isAlive) {
      throw StateError('Actor $id is not alive');
    }

    final effectiveTimeout = timeout ?? _askConfig.defaultTimeout;
    final effectiveMaxRetries = maxRetries ?? _askConfig.maxRetries;
    final effectiveEnableRetries = enableRetries ?? _askConfig.enableRetries;

    int attemptCount = 0;
    Object? lastError;
    final correlationId = 'ask${++_asks}';

    while (attemptCount <= effectiveMaxRetries) {
      try {
        return await _performAsk<T>(
            message, effectiveTimeout, attemptCount, correlationId);
      } catch (error) {
        lastError = error;
        attemptCount++;

        if (!effectiveEnableRetries || attemptCount > effectiveMaxRetries) {
          if (_tracing) {
            _tracer.record(TraceEvent(
              correlationId,
              'ask_failed_final',
              this,
              {
                'error': error.toString(),
                'attempts': attemptCount,
                'timeout': effectiveTimeout.toString(),
              },
            ));
          }
          rethrow;
        }

        if (!_askConfig.isRetryableError(error)) {
          if (_tracing) {
            _tracer.record(TraceEvent(
              correlationId,
              'ask_failed_non_retryable',
              this,
              {
                'error': error.toString(),
                'error_type': error.runtimeType.toString(),
              },
            ));
          }
          rethrow;
        }

        final backoffDuration = _askConfig.calculateBackoff(attemptCount);

        if (_tracing) {
          _tracer.record(TraceEvent(
            correlationId,
            'ask_retry',
            this,
            {
              'attempt': attemptCount,
              'max_retries': effectiveMaxRetries,
              'backoff_ms': backoffDuration.inMilliseconds,
              'error': error.toString(),
            },
          ));
        }

        if (backoffDuration > Duration.zero) {
          await Future.delayed(backoffDuration);
        }
      }
    }

    throw lastError ?? StateError('Ask operation failed after all retries');
  }

  /// Performs a single ask attempt without retry logic.
  Future<T> _performAsk<T>(Object? message, Duration timeout, int attemptNumber,
      String correlationId) {
    if (!_isAlive) {
      throw StateError('Actor $id is not alive');
    }

    final completer = Completer<T>();
    final tempRef = _TemporaryActorRef<T>(completer, attemptNumber);

    if (_tracing) {
      _tracer.record(TraceEvent(
        correlationId,
        'ask_attempt',
        this,
        {
          'attempt': attemptNumber + 1,
          'timeout_ms': timeout.inMilliseconds,
        },
      ));
    }

    // The answer goes to the temporary reference, whoever is asking.
    Sending.as(tempRef, () => tell(message));

    return completer.future.timeout(timeout, onTimeout: () {
      tempRef.stop();
      throw TimeoutException(
        'Ask request to actor $id timed out after ${timeout.inMilliseconds}ms (attempt ${attemptNumber + 1})',
        timeout,
      );
    });
  }

  @override
  void watch(ActorRef watcher) {
    if (!_isAlive) {
      // Too late to see it end; say so, as a link would.
      Sending.system(watcher, Terminated(this, reason: const NoProcExit()));
      return;
    }
    _watchers.add(watcher);
  }

  @override
  void unwatch(ActorRef watcher) => _watchers.remove(watcher);

  /// Marks this ref dead without stopping the actor: the system still holds
  /// it, its timers run and `postStop` is never called.
  @Deprecated('Use ActorSystem.stop or ActorSystem.kill. Will be removed in '
      '3.0.')
  void stop([ExitReason reason = const NormalExit()]) => terminate(reason);

  /// The system's last step in stopping the actor: the ref goes dead, the
  /// mailbox is emptied and watchers are told.
  @internal
  void terminate(ExitReason reason) {
    if (!_isAlive) return;
    _isAlive = false;
    _mailbox.dispose();
    // Taken first: a watcher may unwatch while it is being told.
    final watchers = [..._watchers];
    _watchers.clear();
    for (final watcher in watchers) {
      Sending.system(watcher, Terminated(this, reason: reason));
    }
  }
}

class _TemporaryActorRef<T> implements ActorRef {
  final Completer<T> _completer;
  final int _attemptNumber;

  _TemporaryActorRef(this._completer, [this._attemptNumber = 0]);

  @override
  late final String id = 'temp_${_attemptNumber}_${_completer.hashCode}';

  @override
  bool get isAlive => !_completer.isCompleted;

  @override
  void tell(Object? message) {
    if (!isAlive) return;
    final payload = unwrapLegacy(message);
    if (payload is T) {
      _completer.complete(payload);
    } else {
      _completer.completeError(StateError('Ask response type mismatch. '
          'Expected: $T, but received: ${payload.runtimeType}'));
    }
  }

  @override
  Future<R> ask<R>(Object? message, [Duration? timeout]) {
    throw UnsupportedError('Cannot ask a temporary actor reference.');
  }

  @override
  void watch(ActorRef watcher) {
    throw UnsupportedError('Cannot watch a temporary actor reference.');
  }

  @override
  void unwatch(ActorRef watcher) {}

  void stop() {
    if (isAlive) {
      _completer.completeError(StateError('Temporary actor reference stopped'));
    }
  }
}
