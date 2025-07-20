import 'dart:collection';

import 'package:dactor/src/local_actor_system.dart';
import 'package:dactor/src/message.dart';

class Mailbox {
  final String actorId;
  final LocalActorSystem _system;
  final _queue = Queue<Message>();
  bool _isDisposed = false;

  Mailbox(this.actorId, this._system);

  void enqueue(Message message) {
    if (!_isDisposed) {
      _queue.add(message);
      _system.metrics.gauge('mailbox.size', _queue.length.toDouble(),
          tags: {'actorId': actorId});
      _system.scheduleMailbox(this);
    }
  }

  Message? dequeue() {
    if (_queue.isNotEmpty) {
      final message = _queue.removeFirst();
      _system.metrics.gauge('mailbox.size', _queue.length.toDouble(),
          tags: {'actorId': actorId});
      return message;
    }
    return null;
  }

  bool get isEmpty => _queue.isEmpty;

  bool get isDisposed => _isDisposed;

  void dispose() {
    _isDisposed = true;
    _queue.clear();
  }
}
