import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:test/test.dart';

enum Door { locked, open }

sealed class DoorEvent {}

final class Digit extends DoorEvent {
  final int digit;
  Digit(this.digit);
}

/// Only makes sense while the door is open; postponed until then.
final class Push extends DoorEvent {}

final class Status extends DoorEvent with Call<String> {}

final class Break extends DoorEvent {}

final class Shutdown extends DoorEvent with Call<String> {}

final _log = <String>[];

/// A code lock: the right digits open it, and it locks itself again after
/// [openFor].
class CodeLock extends GenStatem<Door, List<int>, DoorEvent> {
  final List<int> code;
  final Duration openFor;
  CodeLock(this.code, {this.openFor = const Duration(milliseconds: 40)});

  @override
  (Door, List<int>) init() => (Door.locked, const []);

  @override
  void onEnter(Door state, Door? previous, List<int> data) =>
      _log.add('enter ${state.name} from ${previous?.name}');

  @override
  Transition<Door, List<int>> onEvent(
          Door state, DoorEvent event, List<int> data) =>
      switch ((state, event)) {
        (_, final Status q) =>
          keep(reply: q.answer('${state.name} ${data.join()}')),
        (_, final Shutdown q) => halt(reply: q.answer('closing')),
        (_, Break()) => throw StateError('jammed'),
        (Door.locked, Digit(:final digit)) => _digit([...data, digit]),
        (Door.locked, Push()) => postpone(),
        (Door.open, Digit()) => keep(),
        (Door.open, Push()) => _pushed(),
      };

  Transition<Door, List<int>> _digit(List<int> entered) {
    if (entered.length < code.length) return keep(data: entered);
    if (entered.join() == code.join()) {
      return next(Door.open, data: const [], timeout: openFor);
    }
    return keep(data: const []);
  }

  Transition<Door, List<int>> _pushed() {
    _log.add('pushed');
    return keep();
  }

  @override
  Transition<Door, List<int>> onTimeout(Door state, List<int> data) {
    _log.add('timeout in ${state.name}');
    return next(Door.locked);
  }

  @override
  void terminate(Door state, List<int> data) =>
      _log.add('terminate ${state.name}');
}

enum Phase { a, b, c }

/// Postpones 'x' in a, and 'y' in a and b; 'go' advances.
class Stepper extends GenStatem<Phase, int, String> {
  @override
  (Phase, int) init() => (Phase.a, 0);

  @override
  Duration? stateTimeout(Phase state) =>
      state == Phase.c ? const Duration(milliseconds: 20) : null;

  @override
  Transition<Phase, int> onEvent(Phase state, String event, int data) {
    switch ((state, event)) {
      case (Phase.a, 'go'):
        return next(Phase.b);
      case (Phase.b, 'go'):
        return next(Phase.c);
      case (Phase.a, 'x') || (Phase.a, 'y') || (Phase.b, 'y'):
        return postpone();
      case (Phase.b, 'x'):
        _log.add('x in b');
        // Handling x moves on, which gives y its turn.
        return next(Phase.c);
      default:
        _log.add('$event in ${state.name}');
        return keep(data: data + 1);
    }
  }

  @override
  Transition<Phase, int> onTimeout(Phase state, int data) {
    _log.add('default timeout in ${state.name}');
    return keep();
  }
}

void main() {
  late LocalActorSystem system;

  setUp(() {
    _log.clear();
    system = LocalActorSystem();
  });

  tearDown(() => system.shutdown());

  Future<void> settle([int ms = 15]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  Future<TypedRef<DoorEvent>> lock({Duration? openFor}) async =>
      (await system.spawn(
              'lock',
              () => CodeLock([1, 2, 3],
                  openFor: openFor ?? const Duration(milliseconds: 40))))
          .typed();

  test('events move the machine and data follows', () async {
    final door = await lock();
    expect(await door.call(Status()), 'locked ');
    door.tell(Digit(1));
    door.tell(Digit(2));
    expect(await door.call(Status()), 'locked 12');
    door.tell(Digit(3));
    expect(await door.call(Status()), 'open ');
    expect(_log, ['enter locked from null', 'enter open from locked']);
  });

  test('a wrong code resets the data and stays locked', () async {
    final door = await lock();
    for (final d in [3, 2, 1]) {
      door.tell(Digit(d));
    }
    expect(await door.call(Status()), 'locked ');
  });

  test('the state timeout fires while the machine stays in the state',
      () async {
    final door = await lock();
    for (final d in [1, 2, 3]) {
      door.tell(Digit(d));
    }
    expect(await door.call(Status()), 'open ');
    await settle(80);
    expect(await door.call(Status()), 'locked ');
    expect(_log, contains('timeout in open'));
  });

  test('leaving a state cancels its timeout', () async {
    final ref = await system.spawn('stepper', () => Stepper());
    ref.tell('go');
    ref.tell('go');
    await settle(50);
    expect(_log, ['default timeout in c']);
    // Once only: keep() without a timeout does not start another.
    await settle(50);
    expect(_log, ['default timeout in c']);
  });

  test('a postponed event is handled after the state changes', () async {
    final door = await lock(openFor: const Duration(seconds: 5));
    door.tell(Push());
    door.tell(Digit(1));
    await settle();
    expect(_log, isNot(contains('pushed')));
    door.tell(Digit(2));
    door.tell(Digit(3));
    expect(await door.call(Status()), 'open ');
    expect(
        _log, ['enter locked from null', 'enter open from locked', 'pushed']);
  });

  test('postponed events keep their order across several state changes',
      () async {
    final ref = await system.spawn('stepper', () => Stepper());
    for (final event in ['y', 'x', 'z', 'go']) {
      ref.tell(event);
    }
    await settle();
    // z is handled at once in a. go enters b: y is postponed again, x is
    // handled and enters c, where y finally runs.
    expect(_log, ['z in a', 'x in b', 'y in c']);
    expect(await system.sys.getState(ref), (Phase.c, 2));
  });

  test('halt answers and stops the machine', () async {
    final door = await lock();
    expect(await door.call(Shutdown()), 'closing');
    await settle();
    expect(door.isAlive, isFalse);
    expect(_log.last, 'terminate locked');
  });

  test('a throwing handler fails the machine; a restart starts over', () async {
    final door = (await system.spawn('lock', () => CodeLock([1]),
            supervision: OneForOneStrategy(
                decider: (_, __) => SupervisionDecision.restart)))
        .typed<DoorEvent>();
    door.tell(Digit(1));
    expect(await door.call(Status()), 'open ');
    door.tell(Break());
    await settle();
    expect(await door.call(Status()), 'locked ');
  });

  group('timeouts', () {
    late ActorRef ref;
    setUp(() async => ref = await system.spawn('t', () => Timeouts()));
    void send(String event) => ref.tell(event);

    test('an event timeout fires when nothing arrives', () async {
      send('idle');
      await settle(60);
      expect(_log, ['event timeout in a']);
      expect(await system.sys.getState(ref), (Phase.a, 1));
    });

    test('any message cancels an event timeout', () async {
      send('idle');
      await settle(10);
      send('ping');
      await settle(60);
      expect(_log, isEmpty);
    });

    test('a generic timeout survives a change of state', () async {
      send('arm');
      send('move');
      send('move');
      await settle(60);
      expect(_log, ['tick in c']);
    });

    test('setting a generic timeout again restarts it', () async {
      send('arm');
      await settle(20);
      send('arm');
      await settle(20);
      expect(_log, isEmpty);
      await settle(30);
      expect(_log, ['tick in a']);
    });

    test('a null duration cancels a generic timeout', () async {
      send('arm');
      send('disarm');
      await settle(60);
      expect(_log, isEmpty);
    });

    test('other messages do not cancel a generic timeout', () async {
      send('arm');
      for (var i = 0; i < 3; i++) {
        await settle(5);
        send('ping');
      }
      await settle(50);
      expect(_log, ['tick in a']);
    });
  });
}

/// Events are strings: 'idle' arms an event timeout, 'ping' is any message,
/// 'arm' and 'disarm' set and cancel a generic timeout, 'move' changes state.
class Timeouts extends GenStatem<Phase, int, String> {
  @override
  (Phase, int) init() => (Phase.a, 0);

  @override
  Transition<Phase, int> onEvent(Phase state, String event, int data) =>
      switch (event) {
        'idle' => keep(eventTimeout: const Duration(milliseconds: 30)),
        'arm' => keep(timeouts: {'tick': const Duration(milliseconds: 30)}),
        'disarm' => keep(timeouts: {'tick': null}),
        'move' => next(Phase.values[(state.index + 1) % 3]),
        _ => keep(),
      };

  @override
  Transition<Phase, int> onEventTimeout(Phase state, int data) {
    _log.add('event timeout in ${state.name}');
    return keep(data: data + 1);
  }

  @override
  Transition<Phase, int> onGenericTimeout(Object name, Phase state, int data) {
    _log.add('$name in ${state.name}');
    return keep();
  }
}
