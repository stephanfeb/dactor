import 'dart:async';
import 'dart:collection';

import 'package:meta/meta.dart';

import 'package:dactor/src/actor.dart';
import 'package:dactor/src/actor_ref.dart';
import 'package:dactor/src/sys.dart';
import 'package:dactor/src/typed_ref.dart';

const _noReply = Object();

/// What a `GenStatem` handler decided. Build one with the helpers on
/// [GenStatem]: `next`, `keep`, `postpone` and `halt`.
final class Transition<S, D> {
  final _Kind _kind;
  final S? _state;
  final D? _data;
  final bool _hasData;
  final Duration? _timeout;
  final Object? _reply;

  const Transition._(this._kind,
      {S? state,
      D? data,
      bool hasData = false,
      Duration? timeout,
      Object? reply = _noReply})
      : _state = state,
        _data = data,
        _hasData = hasData,
        _timeout = timeout,
        _reply = reply;
}

enum _Kind { next, keep, postpone, halt }

final class _StateTimeout {
  final int generation;
  const _StateTimeout(this.generation);
}

/// A state machine actor, in the manner of OTP's `gen_statem`.
///
/// [S] is the state (usually an enum or a sealed class), [D] the data carried
/// across states, and [M] the events the machine accepts. Every event goes to
/// [onEvent] together with the current state and data, and the handler
/// answers with a transition:
///
/// - [next] moves to another state. Entering a state runs [onEnter], cancels
///   the state timeout of the one left, and replays postponed events.
/// - [keep] stays.
/// - [postpone] stays and puts the event aside until the state changes.
/// - [halt] stops the machine.
///
/// A state timeout, given as `timeout:` on [next] or [keep], calls
/// [onTimeout] if the machine is still in that state when it runs out.
abstract class GenStatem<S, D, M> extends Actor implements StatefulBehaviour {
  static const _timerKey = 'dactor.statem.state_timeout';

  late S _state;
  late D _data;
  bool _initialised = false;
  int _timeoutGeneration = 0;
  var _postponed = Queue<(M, ActorRef?)>();

  /// The state and data the machine starts with.
  @protected
  FutureOr<(S, D)> init();

  /// Handles [event] in [state].
  @protected
  FutureOr<Transition<S, D>> onEvent(S state, M event, D data);

  /// Called when the state timeout runs out. The default stays.
  @protected
  FutureOr<Transition<S, D>> onTimeout(S state, D data) => keep();

  /// Handles a message that is not an [M]. The default ignores it.
  @protected
  FutureOr<Transition<S, D>> onInfo(S state, Object? message, D data) => keep();

  /// Called when the machine enters [state]: once at the start, with
  /// [previous] null, and after every [next] that changes the state.
  @protected
  FutureOr<void> onEnter(S state, S? previous, D data) {}

  /// How long the machine may stay in [state] when the transition into it
  /// gave no `timeout:`. The default is no limit.
  @protected
  Duration? stateTimeout(S state) => null;

  /// Called from `postStop`, unless [init] never completed.
  @protected
  void terminate(S state, D data) {}

  /// The version of this code's state and data layout.
  int get version => 1;

  /// Converts the state and data of the code this machine was upgraded
  /// from. The default expects them to fit already.
  @protected
  FutureOr<(S, D)> codeChange(int oldVersion, Object? old) => old as (S, D);

  /// Move to [state]. [data] replaces the data if given. [reply] answers the
  /// caller of the event being handled. [timeout] starts a state timeout for
  /// the new state.
  @protected
  Transition<S, D> next(S state,
          {D? data, Object? reply = _noReply, Duration? timeout}) =>
      Transition._(_Kind.next,
          state: state,
          data: data,
          hasData: data != null,
          reply: reply,
          timeout: timeout);

  /// Stay in the current state. A [timeout] restarts the state timeout;
  /// without one, a running timeout keeps running.
  @protected
  Transition<S, D> keep(
          {D? data, Object? reply = _noReply, Duration? timeout}) =>
      Transition._(_Kind.keep,
          data: data, hasData: data != null, reply: reply, timeout: timeout);

  /// Stay, and handle the event again after the next change of state.
  @protected
  Transition<S, D> postpone() => const Transition._(_Kind.postpone);

  /// Stop the machine once this handler has returned.
  @protected
  Transition<S, D> halt({Object? reply = _noReply}) =>
      Transition._(_Kind.halt, reply: reply);

  /// The current state. Meant for tests; handlers get it as an argument.
  @visibleForTesting
  S get state => _state;

  /// The current data. Meant for tests; handlers get it as an argument.
  @visibleForTesting
  D get data => _data;

  @override
  @nonVirtual
  Object? get behaviourState => (_state, _data);

  @override
  @nonVirtual
  set behaviourState(Object? value) {
    final (state, data) = value as (S, D);
    final changed = state != _state;
    final previous = _state;
    _state = state;
    _data = data;
    if (changed) {
      _cancelTimeout();
      _armTimeout(stateTimeout(state));
      // Entering by decree: the hooks still run, postponed events wait for
      // the next ordinary transition.
      unawaited(Future.sync(() => onEnter(state, previous, data)));
    }
  }

  @override
  @nonVirtual
  int get behaviourVersion => version;

  @override
  @nonVirtual
  Future<void> preStart() async {
    final ctx = context;
    final handoff = ctx is BehaviourContext
        ? (ctx as BehaviourContext).takeHandoff()
        : null;
    final (state, data) = handoff == null
        ? await init()
        : await codeChange(handoff.version, handoff.state);
    _state = state;
    _data = data;
    _initialised = true;
    if (handoff == null) {
      await onEnter(state, null, data);
    }
    _armTimeout(stateTimeout(state));
  }

  @override
  @nonVirtual
  Future<void> onMessage(dynamic message) async {
    final sender = context.sender;
    final Transition<S, D> transition;
    if (message is _StateTimeout) {
      if (message.generation != _timeoutGeneration) return;
      transition = await onTimeout(_state, _data);
    } else if (message is M) {
      transition = await _handleEvent(message, sender);
    } else {
      transition = await onInfo(_state, message, _data);
    }
    if (transition._kind == _Kind.postpone) {
      if (message is M && message is! _StateTimeout) {
        _postponed.add((message, sender));
      }
      return;
    }
    var changed = await _apply(transition, sender);

    // A change of state gives every postponed event another chance, oldest
    // first. One of them may change the state again, which starts over with
    // whatever is still postponed.
    while (changed && _postponed.isNotEmpty && _initialised) {
      changed = false;
      final retry = _postponed;
      _postponed = Queue();
      while (retry.isNotEmpty) {
        final (event, from) = retry.removeFirst();
        final again = await _handleEvent(event, from);
        if (again._kind == _Kind.postpone) {
          _postponed.add((event, from));
          continue;
        }
        if (await _apply(again, from)) {
          changed = true;
          // The rest go behind anything postponed during this pass, in
          // their original order.
          _postponed = Queue.of([...retry, ..._postponed]);
          break;
        }
      }
    }
  }

  Future<Transition<S, D>> _handleEvent(M event, ActorRef? sender) async {
    try {
      return await onEvent(_state, event, _data);
    } catch (error) {
      if (event is Call) From(sender).reply(CallFailure(error));
      rethrow;
    }
  }

  /// Carries out [transition] and returns whether the state changed.
  Future<bool> _apply(Transition<S, D> transition, ActorRef? sender) async {
    if (transition._hasData) _data = transition._data as D;
    if (!identical(transition._reply, _noReply)) {
      From(sender).reply(transition._reply);
    }
    switch (transition._kind) {
      case _Kind.halt:
        _cancelTimeout();
        unawaited(context.system.stop(context.self));
        return false;
      case _Kind.keep:
        if (transition._timeout != null) _armTimeout(transition._timeout);
        return false;
      case _Kind.next:
        final previous = _state;
        final target = transition._state as S;
        if (target == previous) {
          if (transition._timeout != null) _armTimeout(transition._timeout);
          return false;
        }
        _cancelTimeout();
        _state = target;
        await onEnter(target, previous, _data);
        _armTimeout(transition._timeout ?? stateTimeout(target));
        return true;
      case _Kind.postpone:
        return false;
    }
  }

  void _armTimeout(Duration? after) {
    if (after == null) return;
    _timeoutGeneration++;
    context.timers
        .startSingleTimer(_timerKey, _StateTimeout(_timeoutGeneration), after);
  }

  void _cancelTimeout() {
    _timeoutGeneration++;
    context.timers.cancel(_timerKey);
  }

  @override
  @nonVirtual
  void postStop() {
    if (_initialised) terminate(_state, _data);
  }
}
