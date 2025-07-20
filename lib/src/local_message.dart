import 'package:dactor/src/actor_ref.dart';
import 'package:dactor/src/message.dart';
import 'package:uuid/uuid.dart';

class LocalMessage implements Message {
  @override
  final String correlationId;
  @override
  final ActorRef? replyTo;
  @override
  final DateTime timestamp;
  @override
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
  })  : correlationId = correlationId ?? Uuid().v4(),
        timestamp = timestamp ?? DateTime.now(),
        metadata = metadata ?? {};
}
