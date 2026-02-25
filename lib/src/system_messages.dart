import 'package:dactor/dactor.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

class Terminated implements Message {
  final ActorRef actor;
  @override
  final String correlationId;
  @override
  final DateTime timestamp;

  Terminated(this.actor)
      : correlationId = _uuid.v4(),
        timestamp = DateTime.now();

  @override
  Map<String, dynamic> get metadata => {};

  @override
  ActorRef? get replyTo => null;
}

class DeadLetter implements Message {
  final dynamic message;
  final ActorRef sender;
  final ActorRef recipient;
  @override
  final String correlationId;
  @override
  final DateTime timestamp;

  DeadLetter(this.message, this.sender, this.recipient)
      : correlationId = _uuid.v4(),
        timestamp = DateTime.now();

  @override
  Map<String, dynamic> get metadata => {};

  @override
  ActorRef? get replyTo => null;
}
