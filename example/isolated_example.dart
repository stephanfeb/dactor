import 'dart:async';

import 'package:dactor/dactor.dart';

/// Checks whether numbers are prime, slowly. Asked about a negative number
/// it loops forever, which no actor sharing an isolate could survive.
class PrimeChecker extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {
    if (message is! int) return;
    if (message < 0) {
      while (true) {}
    }
    var prime = message > 1;
    for (var d = 2; d * d <= message; d++) {
      if (message % d == 0) prime = false;
    }
    context.sender?.tell(prime);
  }
}

class Clock extends Actor {
  int ticks = 0;

  @override
  void preStart() => context.timers
      .startTimerAtFixedRate('tick', 'tick', const Duration(milliseconds: 100));

  @override
  Future<void> onMessage(dynamic message) async {
    if (message == 'tick') ticks++;
    if (message == 'read') context.sender?.tell(ticks);
  }
}

SupervisionDecision restart(Object error, StackTrace stack) {
  print('Supervisor saw: $error');
  return SupervisionDecision.restart;
}

void main() async {
  final system = LocalActorSystem();

  // An ordinary actor in the main isolate.
  final clock = await system.spawn('clock', () => Clock());

  // The same kind of spawn, but the actor lives in an isolate of its own.
  final checker = await system.spawn(
      'checker',
      () => Isolated(PrimeChecker.new,
          heartbeat: const Duration(milliseconds: 100),
          unresponsiveAfter: const Duration(milliseconds: 500)),
      supervision: const OneForOneStrategy(decider: restart));

  print('1000003 prime? '
      '${await checker.ask<bool>(1000003)}');

  // Send it into the infinite loop.
  checker.tell(-1);
  await Future<void>.delayed(const Duration(seconds: 1));

  // The clock never stopped ticking, and the checker is back.
  print('Clock ticks meanwhile: '
      '${await clock.ask<int>('read')}');
  print('1000033 prime? '
      '${await checker.ask<bool>(1000033)}');

  await system.shutdown();
}
