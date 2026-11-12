import 'dart:async';

import 'package:dactor/src/actor_ref.dart';

/// Mixed into a message that expects a reply of type [R].
///
/// ```dart
/// sealed class CounterMsg {}
/// final class Increment extends CounterMsg {}
/// final class Get extends CounterMsg with Call<int> {}
/// ```
///
/// A behaviour such as `GenServer` treats a message with this mixin as a
/// call, and [TypedRef.call] returns its reply as an [R].
mixin Call<R> {
  /// The result of a `GenServer.handleCall` that answers this request with
  /// [value] and continues with [state].
  Reply<S> reply<S>(R value, S state) => Reply<S>(value, state);

  /// Answers this request through [from], for a handler that returned
  /// [NoReply] and replies later.
  void replyTo(From from, R value) => from.reply(value);

  /// The answer [value] to this request, for `reply:` on a `GenStatem`
  /// transition. Checks that [value] is an [R].
  Answer answer(R value) => Answer._(value);
}

/// A checked answer to a request, made by [Call.answer].
final class Answer {
  final Object? value;
  const Answer._(this.value);
}

/// What a `GenServer.handleCall` decided.
sealed class CallResult<S> {
  /// The state to continue with.
  final S state;
  const CallResult(this.state);
}

/// Answer the caller and continue. Build it with [Call.reply], which checks
/// the type of the reply.
final class Reply<S> extends CallResult<S> {
  final Object? value;
  const Reply(this.value, super.state);
}

/// Continue without answering yet. The handler keeps the [From] it was given
/// and answers through it later; until then the caller waits, up to its
/// timeout.
final class NoReply<S> extends CallResult<S> {
  const NoReply(super.state);
}

/// Answer the caller, then stop the server normally.
final class StopReply<S> extends CallResult<S> {
  final Object? value;
  const StopReply(this.value, super.state);
}

/// The caller of a request, as far as the server needs to know it.
final class From {
  final ActorRef? _caller;

  /// Wraps the sender of the request being handled. [caller] is null when
  /// the request was sent with `tell` and nobody is waiting.
  const From(ActorRef? caller) : _caller = caller;

  /// Whether anybody is waiting for a reply.
  bool get expectsReply => _caller != null;

  /// Sends [value] to the caller. Prefer [Call.replyTo], which checks the
  /// type of [value] against the request.
  void reply(Object? value) => _caller?.tell(value);
}

/// Sent to the caller in place of a reply when the handler threw.
final class CallFailure {
  final Object error;
  const CallFailure(this.error);
}

/// Thrown by [TypedRef.call] when the server failed while handling the
/// request.
class CallException implements Exception {
  final ActorRef server;
  final Object request;

  /// The error the handler threw.
  final Object error;

  const CallException(this.server, this.request, this.error);

  @override
  String toString() =>
      'CallException: ${server.id} failed handling $request: $error';
}

/// An [ActorRef] that only accepts messages of type [M].
///
/// It is a compile-time view: it costs nothing at run time, and the plain
/// reference is always available as [untyped]. Nothing checks that the actor
/// behind the reference really understands [M]; the type is a promise made
/// where the reference is created, usually next to the `spawn`.
extension type const TypedRef<M>(ActorRef untyped) {
  String get id => untyped.id;

  bool get isAlive => untyped.isAlive;

  /// Sends [message] and does not wait.
  void tell(M message) => untyped.tell(message);

  /// Sends [request] and completes with its reply.
  ///
  /// Fails with a [TimeoutException] if no reply arrives in time, with a
  /// [CallException] if the handler threw, and with a [StateError] if the
  /// actor is not alive.
  Future<R> call<R>(Call<R> request, {Duration? timeout}) async {
    if (request is! M) {
      throw ArgumentError.value(
          request, 'request', 'is not a $M, which is all this actor accepts');
    }
    final answer = await untyped.ask<Object?>(request, timeout);
    if (answer is CallFailure) {
      throw CallException(untyped, request, answer.error);
    }
    return answer as R;
  }
}

extension TypedActorRef on ActorRef {
  /// This reference, restricted to messages of type [M].
  TypedRef<M> typed<M>() => TypedRef<M>(this);
}
