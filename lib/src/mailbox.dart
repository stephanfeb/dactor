import 'dart:collection';

import 'package:dactor/src/message.dart';

class Mailbox {
  final String actorId;
  final void Function(Mailbox mailbox) _onSchedule;
  final void Function(String name, double value, {Map<String, String>? tags})?
      _onGauge;
  final _queue = Queue<Message>();

  /// Messages from the actor system itself. They are delivered before
  /// anything in [_queue], so a backlog cannot hold up supervision.
  Queue<Message>? _system;
  bool _isDisposed = false;

  Mailbox(
    this.actorId,
    this._onSchedule, {
    void Function(String name, double value, {Map<String, String>? tags})?
        onGauge,
  }) : _onGauge = onGauge;

  void enqueue(Message message) {
    if (!_isDisposed) {
      _queue.add(message);
      _onGauge?.call('mailbox.size', _queue.length.toDouble(),
          tags: {'actorId': actorId});
      _onSchedule(this);
    }
  }

  /// Queues a system message ahead of all user messages.
  void enqueueSystem(Message message) {
    if (!_isDisposed) {
      (_system ??= Queue<Message>()).add(message);
      _onSchedule(this);
    }
  }

  Message? dequeue() {
    final system = _system;
    if (system != null && system.isNotEmpty) {
      return system.removeFirst();
    }
    if (_queue.isNotEmpty) {
      final message = _queue.removeFirst();
      _onGauge?.call('mailbox.size', _queue.length.toDouble(),
          tags: {'actorId': actorId});
      return message;
    }
    return null;
  }

  bool get isEmpty => _queue.isEmpty && (_system?.isEmpty ?? true);

  bool get isDisposed => _isDisposed;

  void dispose() {
    _isDisposed = true;
    _queue.clear();
    _system?.clear();
  }
}
