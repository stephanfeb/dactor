import 'package:dactor/src/actor_ref.dart';
import 'package:dactor/src/local_message.dart';

/// A base class for messages that are designed to work seamlessly with the ask pattern.
///
/// This class extends [LocalMessage] and automatically sets the payload to return
/// the message instance itself, which is the expected behavior for ask operations.
///
/// Example usage:
/// ```dart
/// class MyCommand extends AskableMessage {
///   final String data;
///   
///   MyCommand(this.data);
/// }
/// 
/// class MyResponse extends AskableResponse {
///   final String result;
///   
///   MyResponse(this.result);
/// }
/// ```
abstract class AskableMessage extends LocalMessage {
  AskableMessage({
    ActorRef? sender,
    String? correlationId,
    ActorRef? replyTo,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(
    payload: null, // Will be overridden by getter
    sender: sender,
    correlationId: correlationId,
    replyTo: replyTo,
    timestamp: timestamp,
    metadata: metadata,
  );

  @override
  dynamic get payload => this; // Return the message itself
}

/// A base class for response messages in ask operations.
///
/// This is functionally identical to [AskableMessage] but provides semantic
/// clarity when creating response messages for ask operations.
///
/// Example usage:
/// ```dart
/// class ProcessingResult extends AskableResponse {
///   final bool success;
///   final String message;
///   
///   ProcessingResult({required this.success, required this.message});
/// }
/// ```
abstract class AskableResponse extends LocalMessage {
  AskableResponse({
    ActorRef? sender,
    String? correlationId,
    ActorRef? replyTo,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) : super(
    payload: null, // Will be overridden by getter
    sender: sender,
    correlationId: correlationId,
    replyTo: replyTo,
    timestamp: timestamp,
    metadata: metadata,
  );

  @override
  dynamic get payload => this; // Return the response itself
}
