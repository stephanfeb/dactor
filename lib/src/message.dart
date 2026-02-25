import 'package:dactor/src/actor_ref.dart';

/// A message that can be sent between actors.
///
/// Messages should be immutable.
abstract class Message {
  /// The correlation ID of the message.
  String get correlationId;

  /// The actor to reply to.
  ActorRef? get replyTo;

  /// The timestamp of the message.
  DateTime get timestamp;

  /// The metadata of the message.
  Map<String, dynamic> get metadata;
}
