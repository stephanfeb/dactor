import 'dart:collection';

import 'package:meta/meta.dart';

import 'package:dactor/src/actor_ref.dart';

/// A message on its way to an actor, with the sender the runtime stamped on
/// it. Actors never see this: `onMessage` gets the [payload] and
/// `context.sender` the [sender].
@internal
final class Envelope {
  static int _next = 0;

  final Object? payload;
  final ActorRef? sender;

  /// Ties the trace events of one message together. Unique within this
  /// isolate.
  final int id;

  Envelope(this.payload, this.sender) : id = ++_next;

  String get traceId => 'm$id';
}

class Mailbox {
  final String actorId;
  final void Function(Mailbox mailbox) _onSchedule;
  final void Function(String name, double value, {Map<String, String>? tags})?
      _onGauge;
  final _queue = Queue<Envelope>();

  /// Messages from the actor system itself. They are delivered before
  /// anything in [_queue], so a backlog cannot hold up supervision.
  Queue<Envelope>? _system;
  bool _isDisposed = false;

  Mailbox(
    this.actorId,
    this._onSchedule, {
    void Function(String name, double value, {Map<String, String>? tags})?
        onGauge,
  }) : _onGauge = onGauge;

  void enqueue(Envelope message) {
    if (!_isDisposed) {
      _queue.add(message);
      _onGauge?.call('mailbox.size', _queue.length.toDouble(),
          tags: {'actorId': actorId});
      _onSchedule(this);
    }
  }

  /// Queues a user message ahead of the other user messages.
  void enqueueFirst(Envelope message) {
    if (!_isDisposed) {
      _queue.addFirst(message);
      _onGauge?.call('mailbox.size', _queue.length.toDouble(),
          tags: {'actorId': actorId});
      _onSchedule(this);
    }
  }

  /// Queues a system message ahead of all user messages.
  void enqueueSystem(Envelope message) {
    if (!_isDisposed) {
      (_system ??= Queue<Envelope>()).add(message);
      _onSchedule(this);
    }
  }

  Envelope? dequeue() {
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

  bool get hasSystemMessages => _system?.isNotEmpty ?? false;

  /// The next system message, leaving user messages where they are.
  Envelope? dequeueSystem() {
    final system = _system;
    return system != null && system.isNotEmpty ? system.removeFirst() : null;
  }

  /// Removes and returns the first user message that passes [test], leaving
  /// the others in order.
  Envelope? takeFirstWhere(bool Function(Envelope message) test) {
    Envelope? found;
    _queue.removeWhere((message) {
      if (found == null && test(message)) {
        found = message;
        return true;
      }
      return false;
    });
    return found;
  }

  /// The number of user messages waiting.
  int get length => _queue.length;

  bool get isEmpty => _queue.isEmpty && (_system?.isEmpty ?? true);

  bool get isDisposed => _isDisposed;

  void dispose() {
    _isDisposed = true;
    _queue.clear();
    _system?.clear();
  }
}
