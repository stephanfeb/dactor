import 'package:dactor/dactor.dart';

class CounterActor extends Actor {
  int _count = 0;

  @override
  Future<void> onMessage(dynamic message) async {
    // onMessage receives exactly what was told. The runtime records who
    // told it, available as context.sender.
    switch (message) {
      case 'increment':
        _count++;
        print('Count: $_count');
        context.sender?.tell(_count);
      case 'get':
        context.sender?.tell(_count);
    }
  }

  @override
  void preStart() {
    print('Counter actor started');
  }

  @override
  void postStop() {
    print('Counter actor stopped');
  }
}

void main() async {
  final system = ActorSystem.create();
  final actor = await system.spawn('counter', () => CounterActor());

  actor.tell('increment');
  actor.tell('increment');

  // ask completes with the payload of the reply.
  final count = await actor.ask<int>(
    'get',
    Duration(seconds: 1),
  );
  print('Count from ask: $count');

  await system.shutdown();
}
