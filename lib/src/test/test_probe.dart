import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:test/test.dart';

class TestProbe extends Actor {
  final _messageQueue = StreamController<dynamic>.broadcast();
  final _completers = <Completer<dynamic>>[];
  ActorRef? _sender;
  dynamic _lastMessage;

  ActorRef get ref => context.self;
  dynamic get lastMessage => _lastMessage;

  final Completer<TestProbe>? _creationCompleter;

  TestProbe() : _creationCompleter = null {
    _messageQueue.stream.listen((event) {
      _lastMessage = event;
      if (_completers.isNotEmpty) {
        _completers.removeAt(0).complete(event);
      }
    });
  }

  TestProbe.withCompleter(this._creationCompleter) {
    _messageQueue.stream.listen((event) {
      _lastMessage = event;
      if (_completers.isNotEmpty) {
        _completers.removeAt(0).complete(event);
      }
    });
  }

  @override
  void preStart() {
    _creationCompleter?.complete(this);
    super.preStart();
  }

  Future<void> expectMsg(dynamic expected, {Duration? timeout}) {
    final completer = Completer<dynamic>();
    _completers.add(completer);

    var future = completer.future.then((actual) {
      expect(actual, expected);
    });

    if (timeout != null) {
      future = future.timeout(timeout, onTimeout: () {
        throw TimeoutException('Did not receive message in time');
      });
    }

    return future;
  }

  Future<T> expectMsgType<T>({Duration? timeout}) {
    final completer = Completer<dynamic>();
    _completers.add(completer);

    var future = completer.future.then((actual) {
      expect(actual, isA<T>());
      return actual as T;
    });

    if (timeout != null) {
      future = future.timeout(timeout, onTimeout: () {
        throw TimeoutException('Did not receive message of type $T in time');
      });
    }

    return future;
  }

  @override
  Future<void> onMessage(dynamic message) async {
    _sender = context.sender;
    _messageQueue.add(message);
  }

  void reply(dynamic message) {
    _sender?.tell(LocalMessage(payload: message));
  }

  void watch(ActorRef target) {
    target.watch(context.self);
  }

  void dispose() {
    _messageQueue.close();
  }
}
