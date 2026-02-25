import 'dart:async';

import 'package:dactor/src/actor_ref.dart';
import 'package:dactor/src/dead_letter_queue.dart';
import 'package:dactor/src/mailbox.dart';
import 'package:dactor/src/local_message.dart';
import 'package:dactor/src/message.dart';
import 'package:dactor/src/tracing/tracing.dart';
import 'package:dactor/src/ask_config.dart';
import 'package:dactor/src/system_messages.dart';

class LocalActorRef implements ActorRef {
  @override
  final String id;
  final Mailbox _mailbox;
  final DeadLetterQueue _deadLetterQueue;
  final TraceCollector _tracer;
  final AskConfig _askConfig;
  final _watchers = <ActorRef>[];
  bool _isAlive = true;

  LocalActorRef(this.id, this._mailbox, this._deadLetterQueue, this._tracer, this._askConfig);

  @override
  bool get isAlive => _isAlive;

  @override
  void tell(Message message, {ActorRef? sender}) {
    if (_isAlive) {
      final LocalMessage localMessage;
      if (message is LocalMessage) {
        localMessage = (sender != null)
            ? LocalMessage(
                payload: message.payload,
                sender: sender,
                correlationId: message.correlationId,
                replyTo: message.replyTo,
                timestamp: message.timestamp,
                metadata: message.metadata,
              )
            : message;
      } else {
        localMessage = LocalMessage(payload: message, sender: sender);
      }

      _tracer.record(TraceEvent(
          localMessage.correlationId, 'sent', this, localMessage.payload));
      _mailbox.enqueue(localMessage);
    } else {
      final lMessage = message is LocalMessage ? message : LocalMessage(payload: message);
      _deadLetterQueue.enqueue(
          DeadLetter(message, sender ?? lMessage.sender ?? this, this));
    }
  }

  @override
  Future<T> ask<T>(Message message, [Duration? timeout]) {
    return askWithRetry<T>(message, timeout: timeout);
  }

  /// Enhanced ask method with configurable retry logic and better error handling.
  Future<T> askWithRetry<T>(Message message, {
    Duration? timeout,
    int? maxRetries,
    bool? enableRetries,
  }) async {
    if (!_isAlive) {
      throw StateError('Actor ${id} is not alive');
    }

    final effectiveTimeout = timeout ?? _askConfig.defaultTimeout;
    final effectiveMaxRetries = maxRetries ?? _askConfig.maxRetries;
    final effectiveEnableRetries = enableRetries ?? _askConfig.enableRetries;

    int attemptCount = 0;
    Object? lastError;

    while (attemptCount <= effectiveMaxRetries) {
      try {
        return await _performAsk<T>(message, effectiveTimeout, attemptCount);
      } catch (error, stackTrace) {
        lastError = error;
        attemptCount++;

        final correlationId = message is LocalMessage
            ? message.correlationId
            : 'ask_${DateTime.now().millisecondsSinceEpoch}';

        if (!effectiveEnableRetries || attemptCount > effectiveMaxRetries) {
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
          rethrow;
        }

        if (!_askConfig.isRetryableError(error)) {
          _tracer.record(TraceEvent(
            correlationId,
            'ask_failed_non_retryable',
            this,
            {
              'error': error.toString(),
              'error_type': error.runtimeType.toString(),
            },
          ));
          rethrow;
        }

        final backoffDuration = _askConfig.calculateBackoff(attemptCount);

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

        if (backoffDuration > Duration.zero) {
          await Future.delayed(backoffDuration);
        }
      }
    }

    throw lastError ?? StateError('Ask operation failed after all retries');
  }

  /// Performs a single ask attempt without retry logic.
  Future<T> _performAsk<T>(Message message, Duration timeout, int attemptNumber) {

    if (!_isAlive) {
      throw StateError('Actor ${id} is not alive');
    }

    final completer = Completer<T>();
    final tempRef = _TemporaryActorRef<T>(completer, attemptNumber);

    final request = message is LocalMessage
        ? LocalMessage(
            payload: message.payload,
            sender: tempRef,
            correlationId: message.correlationId,
            replyTo: message.replyTo,
            timestamp: message.timestamp,
            metadata: message.metadata,
          )
        : LocalMessage(
            payload: message,
            sender: tempRef,
          );

    _tracer.record(TraceEvent(
      request.correlationId,
      'ask_attempt',
      this,
      {
        'attempt': attemptNumber + 1,
        'timeout_ms': timeout.inMilliseconds,
      },
    ));

    tell(request);

    return completer.future.timeout(timeout, onTimeout: () {
      tempRef.stop();
      throw TimeoutException(
        'Ask request to actor ${id} timed out after ${timeout.inMilliseconds}ms (attempt ${attemptNumber + 1})',
        timeout,
      );
    });
  }

  @override
  void watch(ActorRef watcher) {
    _watchers.add(watcher);
  }

  void stop() {
    if (!_isAlive) return;
    _isAlive = false;
    _mailbox.dispose();
    for (final watcher in _watchers) {
      watcher.tell(LocalMessage(payload: Terminated(this)));
    }
  }
}

class _TemporaryActorRef<T> implements ActorRef {
  final Completer<T> _completer;
  final int _attemptNumber;

  _TemporaryActorRef(this._completer, [this._attemptNumber = 0]);

  @override
  String get id => 'temp_${_attemptNumber}_${_completer.hashCode}';

  @override
  bool get isAlive => !_completer.isCompleted;

  @override
  void tell(Message message, {ActorRef? sender}) {

    if (isAlive) {
      try {
        final localMessage = message as LocalMessage;
        final payload = localMessage.payload;

        if (payload is T) {
          _completer.complete(payload);
        } else {
          _completer.completeError(
            StateError('Ask response type mismatch. Expected: $T, '
                      'but received: ${payload.runtimeType}. '
                      'Response messages should extend LocalMessage and override '
                      'the payload getter to return the response object itself.')
          );
        }
      } catch (e) {
        _completer.completeError(
          StateError('Ask response must be a LocalMessage. '
                    'Received: ${message.runtimeType}. '
                    'Exception: $e')
        );
      }
    }
  }

  @override
  Future<R> ask<R>(Message message, [Duration? timeout]) {
    throw UnsupportedError('Cannot ask a temporary actor reference.');
  }

  @override
  void watch(ActorRef watcher) {
    throw UnsupportedError('Cannot watch a temporary actor reference.');
  }

  void stop() {
    if (isAlive) {
      _completer.completeError(StateError('Temporary actor reference stopped'));
    }
  }
}
