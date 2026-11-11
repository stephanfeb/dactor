import 'package:dactor/dactor.dart';

/// A door with a code lock, after the example in the OTP `gen_statem` guide.
///
/// Entering the right digits opens the door. It locks itself again after a
/// while (a state timeout). Someone who pushes the door while it is locked
/// gets through once it opens (a postponed event).
enum Door { locked, open }

sealed class DoorEvent {}

final class Digit extends DoorEvent {
  final int digit;
  Digit(this.digit);
}

final class Push extends DoorEvent {
  final String who;
  Push(this.who);
}

final class IsOpen extends DoorEvent with Call<bool> {}

/// The data is the digits entered so far.
class CodeLock extends GenStatem<Door, List<int>, DoorEvent> {
  final List<int> code;
  CodeLock(this.code);

  @override
  (Door, List<int>) init() => (Door.locked, const []);

  @override
  void onEnter(Door state, Door? previous, List<int> data) =>
      print('The door is ${state.name}');

  @override
  Transition<Door, List<int>> onEvent(
          Door state, DoorEvent event, List<int> data) =>
      switch ((state, event)) {
        (_, IsOpen()) => keep(reply: state == Door.open),
        (Door.locked, Digit(:final digit)) => _entered([...data, digit]),
        // Not yet: try again when the state changes.
        (Door.locked, Push()) => postpone(),
        (Door.open, Digit()) => keep(),
        (Door.open, Push(:final who)) => _through(who),
      };

  Transition<Door, List<int>> _entered(List<int> digits) {
    if (digits.length < code.length) return keep(data: digits);
    if (digits.join() != code.join()) return keep(data: const []);
    return next(Door.open,
        data: const [], timeout: const Duration(milliseconds: 200));
  }

  Transition<Door, List<int>> _through(String who) {
    print('$who walks through');
    return keep();
  }

  @override
  Transition<Door, List<int>> onTimeout(Door state, List<int> data) =>
      next(Door.locked);
}

void main() async {
  final system = LocalActorSystem();
  final TypedRef<DoorEvent> door =
      (await system.spawn('door', () => CodeLock([4, 2]))).typed();

  door.tell(Push('Ada')); // postponed: the door is locked
  door.tell(Digit(4));
  door.tell(Digit(2)); // opens, and Ada walks through
  print('Open? ${await door.call(IsOpen())}');

  await Future<void>.delayed(const Duration(milliseconds: 300));
  print('Open? ${await door.call(IsOpen())}'); // locked again

  await system.shutdown();
}
