import 'dart:async';

import 'package:meta/meta.dart';

import 'package:dactor/src/actor.dart';
import 'package:dactor/src/sys.dart';
import 'package:dactor/src/typed_ref.dart';

/// An actor written as a set of functions over one state value, in the manner
/// of OTP's `gen_server`.
///
/// [S] is the state and [M] the messages the server accepts. A message that
/// mixes in [Call] is a request and goes to [handleCall]; any other [M] goes
/// to [handleCast]; anything that is not an [M] (a `Terminated`, an
/// `ExitSignal`, a timer message of another type) goes to [handleInfo].
///
/// ```dart
/// sealed class CounterMsg {}
/// final class Increment extends CounterMsg {}
/// final class Get extends CounterMsg with Call<int> {}
///
/// class Counter extends GenServer<int, CounterMsg> {
///   @override
///   int init() => 0;
///
///   @override
///   int handleCast(CounterMsg message, int state) => switch (message) {
///         Increment() => state + 1,
///         Get() => state,
///       };
///
///   @override
///   CallResult<int> handleCall(CounterMsg request, int state, From from) =>
///       switch (request) {
///         Get() => request.reply(state, state),
///         Increment() => NoReply(state),
///       };
/// }
/// ```
///
/// Because the state is a value the handlers return, and not fields they
/// mutate, a handler that throws leaves no half-made change behind, and the
/// system can read the state ([Sys.getState]), replace it, and carry it over
/// to new code ([Sys.upgrade] and [codeChange]).
abstract class GenServer<S, M> extends Actor implements StatefulBehaviour {
  late S _state;
  bool _initialised = false;

  /// The state the server starts with. Runs in `preStart`: a throw here
  /// fails the spawn.
  @protected
  FutureOr<S> init();

  /// Handles a request. Return [Call.reply] to answer and continue,
  /// [NoReply] to answer later through [from], or [StopReply].
  ///
  /// If this throws, the caller's `TypedRef.call` fails with a
  /// `CallException` and the server fails as any actor does.
  @protected
  FutureOr<CallResult<S>> handleCall(M request, S state, From from) =>
      throw UnsupportedError('$runtimeType does not answer $request');

  /// Handles a message that expects no reply and returns the new state.
  @protected
  FutureOr<S> handleCast(M message, S state) => state;

  /// Handles a message that is not an [M] and returns the new state.
  @protected
  FutureOr<S> handleInfo(Object? message, S state) => state;

  /// Called from `postStop` with the last state, unless [init] never
  /// completed.
  @protected
  void terminate(S state) {}

  /// The version of this code's state layout. Raise it when the shape of
  /// [S] changes, and convert in [codeChange].
  int get version => 1;

  /// Converts the state of the code this server was upgraded from. Runs in
  /// place of [init] when the server is started by [Sys.upgrade].
  ///
  /// The default expects the old state to be an [S] already.
  @protected
  FutureOr<S> codeChange(int oldVersion, Object? oldState) => oldState as S;

  /// Stops this server once the current handler has returned.
  @protected
  void stop() => unawaited(context.system.stop(context.self));

  /// The current state. Meant for tests and for `Sys`; handlers get the
  /// state as an argument.
  @visibleForTesting
  S get state => _state;

  @override
  @nonVirtual
  Object? get behaviourState => _state;

  @override
  @nonVirtual
  set behaviourState(Object? value) => _state = value as S;

  @override
  @nonVirtual
  int get behaviourVersion => version;

  @override
  @nonVirtual
  FutureOr<void> preStart() {
    final ctx = context;
    final handoff = ctx is BehaviourContext
        ? (ctx as BehaviourContext).takeHandoff()
        : null;
    final initial =
        handoff == null ? init() : codeChange(handoff.version, handoff.state);
    if (initial is Future<S>) {
      return initial.then(_started);
    }
    _started(initial);
  }

  void _started(S initial) {
    _state = initial;
    _initialised = true;
  }

  @override
  @nonVirtual
  Future<void> onMessage(dynamic message) async {
    if (message is! M) {
      _state = await handleInfo(message, _state);
      return;
    }
    if (message is! Call) {
      _state = await handleCast(message, _state);
      return;
    }
    final from = From(context.sender);
    final CallResult<S> result;
    try {
      result = await handleCall(message, _state, from);
    } catch (error) {
      from.reply(CallFailure(error));
      rethrow;
    }
    _state = result.state;
    switch (result) {
      case Reply(:final value):
        from.reply(value);
      case StopReply(:final value):
        from.reply(value);
        stop();
      case NoReply():
        break;
    }
  }

  @override
  @nonVirtual
  void postStop() {
    if (_initialised) terminate(_state);
  }
}
