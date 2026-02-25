import 'dart:collection';

import 'package:dactor/src/message.dart';
import 'package:dactor/src/metrics/metrics.dart';

class DeadLetterQueue {
  final _queue = Queue<Message>();
  final MetricsCollector _metrics;
  final int maxSize;

  DeadLetterQueue(this._metrics, {this.maxSize = 1000});

  void enqueue(Message message) {
    if (_queue.length >= maxSize) {
      _queue.removeFirst();
      _metrics.increment('dead_letters.evicted');
    }
    _queue.add(message);
    _metrics.increment('dead_letters');
  }

  Message? dequeue() {
    if (_queue.isNotEmpty) {
      return _queue.removeFirst();
    }
    return null;
  }

  bool get isEmpty => _queue.isEmpty;

  int get length => _queue.length;

  void dispose() {
    _queue.clear();
  }
}
