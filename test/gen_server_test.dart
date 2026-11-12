import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:test/test.dart';

sealed class CounterMsg {}

final class Increment extends CounterMsg {
  final int by;
  Increment([this.by = 1]);
}

final class Get extends CounterMsg with Call<int> {}

final class GetLater extends CounterMsg with Call<int> {}

final class Boom extends CounterMsg with Call<int> {}

final class Finish extends CounterMsg with Call<String> {}

final class Unanswered extends CounterMsg with Call<int> {}

final class Silent extends CounterMsg with Call<int> {}

final _log = <String>[];

class Counter extends GenServer<int, CounterMsg> {
  final int start;
  Counter([this.start = 0]);

  @override
  int init() => start;

  @override
  int handleCast(CounterMsg message, int state) => switch (message) {
        Increment(:final by) => state + by,
        _ => state,
      };

  @override
  FutureOr<CallResult<int>> handleCall(
          CounterMsg request, int state, From from) =>
      switch (request) {
        Get() => request.reply(state, state),
        GetLater() => _later(request, state, from),
        Boom() => throw StateError('boom'),
        Finish() => StopReply('bye', state),
        Silent() => NoReply(state),
        _ => super.handleCall(request, state, from),
      };

  CallResult<int> _later(GetLater request, int state, From from) {
    Timer(const Duration(milliseconds: 10),
        () => request.replyTo(from, state * 100));
    return NoReply(state);
  }

  @override
  int handleInfo(Object? message, int state) {
    _log.add('info: $message');
    return state;
  }

  @override
  void terminate(int state) => _log.add('terminate: $state');
}

class AsyncInit extends GenServer<String, Object> {
  @override
  Future<String> init() async {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    return 'ready';
  }
}

class FailingInit extends GenServer<int, Object> {
  @override
  int init() => throw StateError('no init');

  @override
  void terminate(int state) => _log.add('terminate called');
}

sealed class Job {}

final class Work extends Job {
  final String name;
  final List<String> then;
  Work(this.name, [this.then = const []]);
}

final class Ask extends Job with Call<List<String>> {
  final List<String> then;
  Ask([this.then = const []]);
}

/// Logs every step to [_log]; the state is the list of steps so far.
class Continuing extends GenServer<List<String>, Job> {
  final List<String> atInit;
  final Completer<void>? gate;
  Continuing({this.atInit = const [], this.gate});

  @override
  List<String> init() {
    atInit.forEach(continueWith);
    return ['init'];
  }

  @override
  List<String> handleCast(Job message, List<String> state) {
    final work = message as Work;
    work.then.forEach(continueWith);
    _log.add(work.name);
    return [...state, work.name];
  }

  @override
  CallResult<List<String>> handleCall(
      Job request, List<String> state, From from) {
    final ask = request as Ask;
    ask.then.forEach(continueWith);
    return ask.reply(state, state);
  }

  @override
  Future<List<String>> handleContinue(Object? arg, List<String> state) async {
    if (arg == 'wait') await gate!.future;
    if (arg == 'fail') throw StateError('continue failed');
    if (arg == 'chain') continueWith('chained');
    _log.add('continue $arg');
    return [...state, 'continue $arg'];
  }
}

void main() {
  late LocalActorSystem system;

  setUp(() {
    _log.clear();
    system = LocalActorSystem();
  });

  tearDown(() => system.shutdown());

  Future<TypedRef<CounterMsg>> counter([int start = 0]) async =>
      (await system.spawn('counter', () => Counter(start))).typed();

  test('casts change the state and calls read it, with static types', () async {
    final ref = await counter();
    ref.tell(Increment());
    ref.tell(Increment(4));
    final int count = await ref.call(Get());
    expect(count, 5);
  });

  test('a call can be answered later through From', () async {
    final ref = await counter(3);
    expect(await ref.call(GetLater()), 300);
  });

  test('a handler that throws fails the call with CallException', () async {
    final ref = await counter();
    await expectLater(
        ref.call(Boom()),
        throwsA(isA<CallException>()
            .having((e) => e.error, 'error', isA<StateError>())));
  });

  test('a throw leaves the state as it was; the restart runs init again',
      () async {
    final ref = (await system.spawn('sup-counter', () => Counter(7),
            supervision: OneForOneStrategy(
                decider: (_, __) => SupervisionDecision.resume)))
        .typed<CounterMsg>();
    ref.tell(Increment());
    await expectLater(ref.call(Boom()), throwsA(isA<CallException>()));
    expect(await ref.call(Get()), 8);
  });

  test('a request the server does not answer fails the call', () async {
    final ref = await counter();
    await expectLater(
        ref.call(Unanswered()),
        throwsA(isA<CallException>()
            .having((e) => e.error, 'error', isA<UnsupportedError>())));
  });

  test('StopReply answers, then stops and runs terminate', () async {
    final ref = await counter(2);
    expect(await ref.call(Finish()), 'bye');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(ref.isAlive, isFalse);
    expect(_log, ['terminate: 2']);
  });

  test('messages of other types go to handleInfo', () async {
    final ref = await counter();
    ref.untyped.tell('hello');
    expect(await ref.call(Get()), 0);
    expect(_log, ['info: hello']);
  });

  test('init may be asynchronous', () async {
    final ref = await system.spawn('async', () => AsyncInit());
    expect(await system.sys.getState(ref), 'ready');
  });

  test('a failing init fails the spawn and skips terminate', () async {
    await expectLater(
        system.spawn('bad', () => FailingInit()), throwsA(isA<StateError>()));
    expect(_log, isEmpty);
  });

  test('call refuses a request outside the message type', () async {
    final ref =
        (await system.spawn('counter', () => Counter())).typed<Increment>();
    // Get is a Call<int> but not an Increment.
    await expectLater(ref.call(Get()), throwsArgumentError);
  });

  group('handleContinue', () {
    test('a cast\'s continues run in order before the next message', () async {
      final ref = (await system.spawn('c', () => Continuing())).typed<Job>();
      ref.tell(Work('a', ['1', 'chain', '2']));
      ref.tell(Work('b'));
      expect(await ref.call(Ask()), [
        'init',
        'a',
        'continue 1',
        'continue chain',
        'continue 2',
        'continue chained',
        'b'
      ]);
    });

    test('a call is answered before its continue runs', () async {
      final gate = Completer<void>();
      final ref =
          (await system.spawn('c', () => Continuing(gate: gate))).typed<Job>();
      // The reply arrives while the continue is still waiting on the gate.
      expect(await ref.call(Ask(['wait'])), ['init']);
      expect(_log, isEmpty);
      gate.complete();
      expect(await ref.call(Ask()), ['init', 'continue wait']);
    });

    test('init\'s continue does not hold up spawn, and runs first', () async {
      final gate = Completer<void>();
      final ref = (await system.spawn(
              'c', () => Continuing(atInit: ['wait', 'x'], gate: gate)))
          .typed<Job>();
      // spawn returned while the continue waits.
      ref.tell(Work('a'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(_log, isEmpty);
      gate.complete();
      expect(
          await ref.call(Ask()), ['init', 'continue wait', 'continue x', 'a']);
    });

    test('a throwing continue fails the server', () async {
      final ref = (await system.spawn('c', () => Continuing(),
              supervision: OneForOneStrategy(
                  decider: (_, __) => SupervisionDecision.restart)))
          .typed<Job>();
      ref.tell(Work('a', ['fail']));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // Restarted: init ran again and the work is gone.
      expect(await ref.call(Ask()), ['init']);
    });
  });

  test('call times out when nobody answers', () async {
    final ref = await counter();
    await expectLater(
        ref.call(Silent(), timeout: const Duration(milliseconds: 30)),
        throwsA(isA<TimeoutException>()));
  });
}
