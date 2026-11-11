import 'dart:async';
import 'dart:isolate';

import 'package:dactor/src/actor.dart';
import 'package:dactor/src/actor_ref.dart';
import 'package:dactor/src/local_actor_ref.dart';
import 'package:dactor/src/local_actor_system.dart';
import 'package:dactor/src/local_message.dart';
import 'package:dactor/src/logging/logging.dart';
import 'package:dactor/src/message.dart';
import 'package:dactor/src/one_for_one_strategy.dart';
import 'package:dactor/src/supervision.dart';
import 'package:dactor/src/system_messages.dart';

/// The isolate of an [Isolated] actor stopped answering and was killed.
class IsolateUnresponsive implements Exception {
  final String actorId;

  /// How long it had been silent.
  final Duration silentFor;

  const IsolateUnresponsive(this.actorId, this.silentFor);

  @override
  String toString() => 'IsolateUnresponsive: the isolate of $actorId did not '
      'answer for ${silentFor.inMilliseconds} ms and was killed';
}

/// The isolate of an [Isolated] actor ended without being asked to.
class IsolateExited implements Exception {
  final String actorId;
  const IsolateExited(this.actorId);

  @override
  String toString() => 'IsolateExited: the isolate of $actorId ended';
}

/// Stands in for an error raised in another isolate that could not be sent
/// across as an object.
class RemoteActorError implements Exception {
  /// `toString()` of the original error.
  final String description;
  const RemoteActorError(this.description);

  @override
  String toString() => 'RemoteActorError: $description';
}

/// Runs an actor in an isolate of its own.
///
/// ```dart
/// final cruncher = await system.spawn('cruncher', () => Isolated(Cruncher.new));
/// ```
///
/// `Isolated` is an ordinary actor in the system that spawned it. It starts
/// an isolate, creates the real actor there from [factory], and hands it one
/// message at a time, waiting for each to be handled. Everything that works
/// on an actor works on this one: `tell`, `ask`, supervision, child specs,
/// links, watches and pools.
///
/// What the isolate adds:
///
/// - **Its own heap.** Messages are copied in and out; nothing is shared.
/// - **Its own thread.** A long computation does not hold up other actors.
/// - **It can be killed whatever it is doing.** A watchdog pings the isolate
///   every [heartbeat]. If no answer comes for [unresponsiveAfter], because
///   the actor is stuck in a loop, the isolate is killed and this actor fails
///   with [IsolateUnresponsive]. Its supervisor then decides, and a restart
///   starts a fresh isolate.
///
/// What changes for the actor inside:
///
/// - `context.system` is a system of its own inside the isolate. Actors it
///   spawns live there with it and die with it.
/// - `context.sender` is a reference back to the sender in the home system.
///   It supports `tell` and `ask`, not `watch`.
/// - Messages in either direction must be sendable between isolates. One
///   that is not goes to the dead letters and a warning is logged. An
///   `ActorRef` of the home system is not sendable; only the sender travels.
/// - An error in a handler is reported to this actor's supervisor in the
///   home system. `resume` keeps the isolate and its state; `restart` and
///   `stop` end the isolate.
///
/// [factory] is sent to the new isolate, so it must not capture anything
/// unsendable. A constructor tear-off (`Cruncher.new`) or a top-level
/// function is always safe. A closure written inside a method may drag the
/// method's other variables along with it.
class Isolated extends Actor {
  /// Creates the real actor, inside the isolate.
  final Actor Function() factory;

  /// How often the watchdog pings the isolate. Null turns the watchdog off.
  final Duration? heartbeat;

  /// How long the isolate may stay silent before it is killed. An actor that
  /// computes for longer than this without an `await` looks stuck, so raise
  /// it for long synchronous work.
  final Duration unresponsiveAfter;

  /// How long the isolate and the actor's `preStart` may take to come up.
  final Duration startTimeout;

  /// How long a stopped isolate gets to run `postStop` before it is killed.
  final Duration shutdownGrace;

  Isolated(
    this.factory, {
    this.heartbeat = const Duration(seconds: 1),
    this.unresponsiveAfter = const Duration(seconds: 5),
    this.startTimeout = const Duration(seconds: 30),
    this.shutdownGrace = const Duration(seconds: 2),
  });

  Isolate? _isolate;
  SendPort? _port;
  RawReceivePort? _inbox;
  ReceivePort? _exits;
  Timer? _watchdog;
  final _clock = Stopwatch();
  int _lastAnswer = 0;

  /// The message the isolate is handling, if any.
  Completer<void>? _pending;
  int _seq = 0;

  /// True once the isolate's end is expected.
  bool _ending = false;

  /// Senders that have no id in the system (the temporary refs of `ask`),
  /// by the token the isolate knows them under.
  final _temporary = <int, ActorRef>{};
  int _nextToken = 0;

  @override
  Future<void> preStart() async {
    final ready = Completer<SendPort>();
    // A raw port, so that its handler can be replaced when this actor stops
    // (see [_release]). Raw handlers run in the root zone unless bound.
    final inbox = _inbox = RawReceivePort()
      ..handler = Zone.current.bindUnaryCallbackGuarded<Object?>(
          (message) => _fromIsolate(message, ready));
    final exits = _exits = ReceivePort();
    exits.listen((_) => _exited(ready));

    try {
      try {
        _isolate = await Isolate.spawn(
            _isolateMain, _Boot(factory, inbox.sendPort, context.self.id),
            onExit: exits.sendPort,
            errorsAreFatal: false,
            debugName: 'dactor:${context.self.id}');
      } on ArgumentError catch (e) {
        throw ArgumentError(
            'The factory of ${context.self.id} cannot be sent to another '
            'isolate. Use a constructor tear-off or a top-level function, or '
            'make sure the closure captures nothing unsendable. ($e)');
      }
      _port = await ready.future.timeout(startTimeout, onTimeout: () {
        throw TimeoutException(
            'The isolate of ${context.self.id} did not start', startTimeout);
      });
    } catch (_) {
      _release(graceful: false);
      rethrow;
    }

    final every = heartbeat;
    if (every != null) {
      _clock.start();
      _lastAnswer = _clock.elapsedMicroseconds;
      _watchdog = Timer.periodic(every, (_) => _checkPulse());
    }
  }

  @override
  Future<void> onMessage(dynamic message) async {
    final port = _port;
    if (port == null) return;
    final sender = context.sender;
    final pending = Completer<void>();
    try {
      port.send(
          ('msg', ++_seq, message, sender == null ? null : _tokenFor(sender)));
    } on ArgumentError catch (e) {
      _undeliverable(message, sender, e);
      return;
    }
    _pending = pending;
    try {
      await pending.future;
    } finally {
      if (identical(_pending, pending)) _pending = null;
    }
  }

  @override
  void postStop() => _release(graceful: true);

  void _fromIsolate(Object? message, Completer<SendPort> ready) {
    _lastAnswer = _clock.elapsedMicroseconds;
    switch (message) {
      case 'pong':
        break;
      case ('ready', SendPort port):
        if (!ready.isCompleted) ready.complete(port);
      case ('start_failed', Object error, String stack):
        _ending = true;
        if (!ready.isCompleted) {
          ready.completeError(error, StackTrace.fromString(stack));
        }
      case ('ack', int seq):
        final pending = _pending;
        if (seq == _seq && pending != null && !pending.isCompleted) {
          pending.complete();
        }
      case ('failed', Object error, String stack):
        _fail(error, StackTrace.fromString(stack));
      case 'exited':
        // The actor stopped itself inside the isolate.
        _ending = true;
        final pending = _pending;
        if (pending != null && !pending.isCompleted) pending.complete();
        unawaited(context.system.stop(context.self));
      case ('tell', Object token, Object? payload, bool withSender):
        _resolve(token)?.tell(LocalMessage(payload: payload),
            sender: withSender ? context.self : null);
      case ('ask', Object token, Object? payload, SendPort reply, int? micros):
        final target = _resolve(token);
        if (target == null) {
          reply.send(('err', RemoteActorError('No such actor: $token')));
          return;
        }
        target
            .ask<Object?>(LocalMessage(payload: payload),
                micros == null ? null : Duration(microseconds: micros))
            .then((value) => reply.send(('ok', value)),
                onError: (Object e) => reply.send(('err', _sendable(e))));
    }
  }

  void _exited(Completer<SendPort> ready) {
    _isolate = null;
    if (_ending) return;
    _ending = true;
    final error = IsolateExited(context.self.id);
    if (!ready.isCompleted) {
      ready.completeError(error, StackTrace.current);
    } else {
      _fail(error, StackTrace.current);
    }
  }

  void _checkPulse() {
    final silent = _clock.elapsedMicroseconds - _lastAnswer;
    if (silent > unresponsiveAfter.inMicroseconds) {
      _ending = true;
      _watchdog?.cancel();
      _isolate?.kill(priority: Isolate.immediate);
      // Dead: nothing left to shut down gracefully.
      _isolate = null;
      _fail(
          IsolateUnresponsive(context.self.id, Duration(microseconds: silent)),
          StackTrace.current);
    } else {
      _port?.send('ping');
    }
  }

  /// Fails this actor: through the handler in flight if there is one,
  /// otherwise as an uncaught error in its zone. Both reach its supervisor.
  void _fail(Object error, StackTrace stackTrace) {
    final pending = _pending;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(error, stackTrace);
    } else {
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Object _tokenFor(ActorRef sender) {
    if (sender is LocalActorRef &&
        identical(context.system.getActor(sender.id), sender)) {
      return sender.id;
    }
    if (_temporary.length >= 64) {
      _temporary.removeWhere((_, ref) => !ref.isAlive);
    }
    final token = _nextToken++;
    _temporary[token] = sender;
    return token;
  }

  ActorRef? _resolve(Object token) => switch (token) {
        String id => context.system.getActor(id),
        int temporary => _temporary[temporary],
        _ => null,
      };

  void _undeliverable(Object? message, ActorRef? sender, Object cause) {
    final system = context.system;
    if (system is! LocalActorSystem) return;
    system.deadLetterQueue
        .enqueue(DeadLetter(message, sender ?? context.self, context.self));
    system.logger.record(LogRecord(
        LogLevel.warning,
        'A ${message.runtimeType} for ${context.self.id} cannot be sent to '
        'its isolate and was dropped: $cause',
        actor: context.self));
  }

  /// Lets go of the isolate. Safe to call twice.
  void _release({required bool graceful}) {
    _ending = true;
    _watchdog?.cancel();
    _exits?.close();
    final inbox = _inbox;
    _inbox = null;
    final isolate = _isolate;
    final port = _port;
    _isolate = null;
    _port = null;
    if (isolate == null || !graceful || port == null) {
      inbox?.close();
      isolate?.kill(priority: Isolate.immediate);
      return;
    }
    port.send('stop');
    // This actor's zone is about to be switched off, so what is left to do
    // has to live outside it: pass on what the actor sends from `postStop`,
    // and kill the isolate if it does not end in time.
    final grace = shutdownGrace;
    final system = context.system;
    final temporary = Map.of(_temporary);
    Zone.root.run(() {
      inbox?.handler = (Object? message) {
        if (message case ('tell', Object token, Object? payload, bool _)) {
          final target = switch (token) {
            String id => system.getActor(id),
            _ => temporary[token],
          };
          target?.tell(LocalMessage(payload: payload));
        }
      };
      final gone = RawReceivePort();
      void finish() {
        gone.close();
        inbox?.close();
      }

      // An exit listener added to an isolate that is already dead never
      // fires, so the deadline closes the ports as well. An open port would
      // keep the whole program alive.
      final deadline = Timer(grace, () {
        isolate.kill(priority: Isolate.immediate);
        finish();
      });
      gone.handler = (_) {
        deadline.cancel();
        finish();
      };
      isolate.addOnExitListener(gone.sendPort);
    });
  }
}

/// A message from the home system, numbered so it can be acknowledged.
class _FromHome {
  final int seq;
  final Object? payload;
  _FromHome(this.seq, this.payload);
}

class _Boot {
  final Actor Function() factory;
  final SendPort home;
  final String id;
  _Boot(this.factory, this.home, this.id);
}

/// [error] itself if it can cross isolates, otherwise its description.
Object _sendable(Object error) {
  try {
    // A send copies the object, and throws if it cannot be copied.
    final probe = RawReceivePort();
    try {
      probe.sendPort.send(error);
    } finally {
      probe.close();
    }
    return error;
  } catch (_) {
    return RemoteActorError('$error');
  }
}

void _report(SendPort home, String kind, Object error, StackTrace stack) =>
    home.send((kind, _sendable(error), '$stack'));

Future<void> _isolateMain(_Boot boot) async {
  final home = boot.home;
  final inbox = ReceivePort();
  final system = LocalActorSystem();
  var stopping = false;

  final ActorRef ref;
  try {
    ref = await system.spawn(
        boot.id, () => _Hosted(boot.factory, home, () => stopping),
        // The decision belongs to the supervisor in the home system. Here
        // the actor is kept as it is until that decision arrives.
        supervision: OneForOneStrategy(
            decider: (error, stack) {
              _report(home, 'failed', error, stack);
              return SupervisionDecision.resume;
            },
            maxRestarts: 1 << 30));
  } catch (e, s) {
    _report(home, 'start_failed', e, s);
    inbox.close();
    Isolate.exit();
  }

  inbox.listen((message) async {
    switch (message) {
      case 'ping':
        home.send('pong');
      case ('msg', int seq, Object? payload, Object? sender):
        ref.tell(LocalMessage(payload: _FromHome(seq, payload)),
            sender: sender == null ? null : _HomeRef(home, sender));
      case 'stop':
        stopping = true;
        await system.shutdown();
        inbox.close();
        Isolate.exit();
    }
  });
  home.send(('ready', inbox.sendPort));
}

/// The real actor's stand-in inside the isolate: it shares its context with
/// the real actor and acknowledges each message from home once handled.
class _Hosted extends Actor {
  final Actor Function() factory;
  final SendPort home;
  final bool Function() stopping;
  late final Actor inner = factory();

  _Hosted(this.factory, this.home, this.stopping);

  @override
  FutureOr<void> preStart() {
    inner.context = context;
    // ignore: invalid_use_of_protected_member
    return inner.preStart();
  }

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is _FromHome) {
      // ignore: invalid_use_of_protected_member
      await inner.onMessage(message.payload);
      home.send(('ack', message.seq));
    } else {
      // ignore: invalid_use_of_protected_member
      await inner.onMessage(message);
    }
  }

  @override
  // ignore: invalid_use_of_protected_member
  void onError(Object error, StackTrace stackTrace) =>
      inner.onError(error, stackTrace);

  @override
  void postStop() {
    try {
      // ignore: invalid_use_of_protected_member
      inner.postStop();
    } finally {
      if (!stopping()) home.send('exited');
    }
  }
}

/// A reference, held inside the isolate, to an actor of the home system.
class _HomeRef implements ActorRef {
  final SendPort _home;
  final Object _token;
  _HomeRef(this._home, this._token);

  @override
  String get id =>
      switch (_token) { String id => id, _ => 'home-temp-$_token' };

  /// Not known from here; assumed.
  @override
  bool get isAlive => true;

  static Object? _payload(Message message) =>
      message is LocalMessage ? message.payload : message;

  @override
  void tell(Message message, {ActorRef? sender}) =>
      _home.send(('tell', _token, _payload(message), sender != null));

  @override
  Future<T> ask<T>(Message message, [Duration? timeout]) async {
    final reply = ReceivePort();
    try {
      _home.send((
        'ask',
        _token,
        _payload(message),
        reply.sendPort,
        timeout?.inMicroseconds
      ));
      final answer = await reply.first;
      switch (answer) {
        case ('ok', final Object? value):
          return value as T;
        case ('err', final Object error):
          throw error;
        default:
          throw StateError('Unexpected answer from the home system: $answer');
      }
    } finally {
      reply.close();
    }
  }

  @override
  void watch(ActorRef watcher) => throw UnsupportedError(
      'An actor inside an isolate cannot watch an actor of the home system');
}
