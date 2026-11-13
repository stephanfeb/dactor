/// What a full mailbox does with a message that does not fit.
enum OverflowPolicy {
  /// The new message goes to the dead letters.
  dropNewest,

  /// The oldest waiting message goes to the dead letters, and the new one
  /// is queued.
  dropOldest,

  /// The new message goes to the dead letters and the actor fails with
  /// [MailboxOverflow], so its supervisor decides what happens to it. The
  /// messages already waiting stay in the mailbox.
  fail,
}

/// How many messages an actor's mailbox holds, and what happens when it is
/// full.
///
/// Only ordinary messages count. Messages from the runtime itself, such as
/// supervision and `Terminated`, are always accepted. Every message turned
/// away is counted under the `mailbox.overflow` metric, tagged with the
/// actor's id.
class MailboxConfig {
  /// The most messages that may wait. Null means no limit.
  final int? capacity;

  final OverflowPolicy overflow;

  const MailboxConfig(
      {this.capacity, this.overflow = OverflowPolicy.dropNewest})
      : assert(capacity == null || capacity > 0, 'capacity must be positive');

  /// No limit. The default.
  static const unbounded = MailboxConfig();
}

/// An actor's mailbox was full under [OverflowPolicy.fail].
class MailboxOverflow implements Exception {
  /// The actor whose mailbox was full.
  final String actorId;

  final int capacity;

  const MailboxOverflow(this.actorId, this.capacity);

  @override
  String toString() =>
      'MailboxOverflow: the mailbox of $actorId is full ($capacity messages)';
}
