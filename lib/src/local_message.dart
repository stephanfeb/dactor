import 'package:dactor/src/actor_ref.dart';
import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';

/// [message], or its payload if it is a deprecated [LocalMessage].
@internal
Object? unwrapLegacy(Object? message) =>
    // ignore: deprecated_member_use_from_same_package
    message is LocalMessage ? message.payload : message;

@Deprecated('Tell the payload itself: ref.tell(payload). '
    'A LocalMessage told is unwrapped to its payload, and its sender, '
    'correlationId and replyTo are ignored. Removed in 3.0.')
class LocalMessage {
  static const _uuid = Uuid();

  final String correlationId;
  final ActorRef? replyTo;
  final DateTime timestamp;
  final Map<String, dynamic> metadata;

  final dynamic payload;
  final ActorRef? sender;

  LocalMessage({
    this.payload,
    this.sender,
    String? correlationId,
    this.replyTo,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  })  : correlationId = correlationId ?? _uuid.v4(),
        timestamp = timestamp ?? DateTime.now(),
        metadata = metadata ?? {};
}
