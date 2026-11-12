// A copy of the probe in package:dactor_test, kept here so that dactor's
// own tests do not depend on a package that depends on dactor.
import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:test/test.dart';

/// An actor that records what it is told, for assertions in tests.
class TestProbe extends Actor {
  final _messages = StreamController<dynamic>.broadcast();
  final _waiting = <Completer<dynamic>>[];
  final Completer<TestProbe>? _created;
  ActorRef? _sender;
  dynamic _lastMessage;

  TestProbe() : _created = null {
    _listen();
  }

  TestProbe.withCompleter(this._created) {
    _listen();
  }

  void _listen() {
    _messages.stream.listen((event) {
      _lastMessage = event;
      if (_waiting.isNotEmpty) _waiting.removeAt(0).complete(event);
    });
  }

  ActorRef get ref => context.self;
  dynamic get lastMessage => _lastMessage;

  @override
  void preStart() {
    _created?.complete(this);
    super.preStart();
  }

  Future<void> expectMsg(dynamic expected, {Duration? timeout}) =>
      _next(timeout, 'Did not receive message in time')
          .then((actual) => expect(actual, expected));

  Future<T> expectMsgType<T>({Duration? timeout}) =>
      _next(timeout, 'Did not receive message of type $T in time')
          .then((actual) {
        expect(actual, isA<T>());
        return actual as T;
      });

  Future<dynamic> _next(Duration? timeout, String error) {
    final completer = Completer<dynamic>();
    _waiting.add(completer);
    final future = completer.future;
    if (timeout == null) return future;
    return future.timeout(timeout, onTimeout: () {
      throw TimeoutException(error);
    });
  }

  @override
  Future<void> onMessage(dynamic message) async {
    _sender = context.sender;
    _messages.add(message);
  }

  /// Tells [message] to the sender of the last message received.
  void reply(dynamic message) => _sender?.tell(message);

  void watch(ActorRef target) => target.watch(context.self);

  void dispose() => _messages.close();
}

/// A [LocalActorSystem] that can create [TestProbe]s.
class TestActorSystem extends LocalActorSystem {
  int _probes = 0;

  TestActorSystem([super.config]);

  Future<TestProbe> createProbe() async {
    final created = Completer<TestProbe>();
    await spawn('probe-${_probes++}', () => TestProbe.withCompleter(created));
    return created.future;
  }
}
