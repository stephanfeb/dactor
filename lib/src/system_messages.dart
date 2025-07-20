import 'package:dactor/dactor.dart';
import 'package:uuid/uuid.dart';

class Terminated implements Message {
  final ActorRef actor;

  Terminated(this.actor);

  @override
  String get correlationId => Uuid().v4();

  @override
  Map<String, dynamic> get metadata => {};

  @override
  ActorRef? get replyTo => null;

  @override
  DateTime get timestamp => DateTime.now();
}

class DeadLetter implements Message {
  final dynamic message;
  final ActorRef sender;
  final ActorRef recipient;

  DeadLetter(this.message, this.sender, this.recipient);

  @override
  String get correlationId => Uuid().v4();

  @override
  Map<String, dynamic> get metadata => {};

  @override
  ActorRef? get replyTo => null;

  @override
  DateTime get timestamp => DateTime.now();
}
