import 'dart:collection';

import 'package:dactor/src/message.dart';
import 'package:dactor/src/metrics/metrics.dart';

class DeadLetterQueue {
  final _queue = Queue<Message>();
  final MetricsCollector _metrics;

  DeadLetterQueue(this._metrics);

  void enqueue(Message message) {
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

  void dispose() {
    _queue.clear();
  }
}
