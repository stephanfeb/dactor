import 'package:dactor/dactor.dart';

class CounterActor extends Actor {
  int _count = 0;

  @override
  Future<void> onMessage(dynamic message) async {
    // onMessage receives the payload, not the LocalMessage envelope.
    // The sender is available through the context.
    switch (message) {
      case 'increment':
        _count++;
        print('Count: $_count');
        context.sender?.tell(LocalMessage(payload: _count));
      case 'get':
        context.sender?.tell(LocalMessage(payload: _count));
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

  actor.tell(LocalMessage(payload: 'increment'));
  actor.tell(LocalMessage(payload: 'increment'));

  // ask completes with the payload of the reply.
  final count = await actor.ask<int>(
    LocalMessage(payload: 'get'),
    Duration(seconds: 1),
  );
  print('Count from ask: $count');

  await system.shutdown();
}
