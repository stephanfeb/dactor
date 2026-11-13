import 'dart:async';
import 'dart:collection';

import 'package:dactor/src/system_messages.dart';
import 'package:dactor/src/metrics/metrics.dart';

/// Messages that could not be delivered, oldest first, at most [maxSize].
///
/// Read them by draining [dequeue], or follow them as they arrive on
/// [letters].
class DeadLetterQueue {
  final _queue = Queue<DeadLetter>();
  final _letters = StreamController<DeadLetter>.broadcast(sync: true);
  final MetricsCollector _metrics;
  final int maxSize;

  DeadLetterQueue(this._metrics, {this.maxSize = 1000});

  void enqueue(DeadLetter message) {
    if (_queue.length >= maxSize) {
      _queue.removeFirst();
      _metrics.increment('dead_letters.evicted');
    }
    _queue.add(message);
    _metrics.increment('dead_letters');
    if (_letters.hasListener) _letters.add(message);
  }

  /// Every dead letter as it arrives, whether or not it is later dequeued.
  /// Closes when the actor system shuts down.
  Stream<DeadLetter> get letters => _letters.stream;

  DeadLetter? dequeue() {
    if (_queue.isNotEmpty) {
      return _queue.removeFirst();
    }
    return null;
  }

  bool get isEmpty => _queue.isEmpty;

  int get length => _queue.length;

  void dispose() {
    _queue.clear();
    _letters.close();
  }
}
