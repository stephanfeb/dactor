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
@Deprecated('Ask with any value: ref.ask<Reply>(request). Removed in 3.0.')
// ignore: deprecated_member_use_from_same_package
abstract class AskableMessage extends LocalMessage {
  AskableMessage({
    super.sender,
    super.correlationId,
    super.replyTo,
    super.timestamp,
    super.metadata,
  }) : super(payload: null); // the payload getter returns this

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
@Deprecated('Answer with any value: context.sender?.tell(reply). '
    'Removed in 3.0.')
// ignore: deprecated_member_use_from_same_package
abstract class AskableResponse extends LocalMessage {
  AskableResponse({
    super.sender,
    super.correlationId,
    super.replyTo,
    super.timestamp,
    super.metadata,
  }) : super(payload: null); // the payload getter returns this

  @override
  dynamic get payload => this; // Return the response itself
}
