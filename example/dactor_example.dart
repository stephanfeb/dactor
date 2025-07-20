import 'package:dactor/dactor.dart';
import 'package:dactor/src/local_actor_system.dart';
import 'package:dactor/src/local_message.dart';

class CounterActor extends Actor {
  int _count = 0;

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is LocalMessage) {
      if (message.payload == 'increment') {
        _count++;
        print('Count: $_count');
        message.sender?.tell(LocalMessage(payload: _count));
      } else if (message.payload == 'get') {
        message.sender?.tell(LocalMessage(payload: _count));
      }
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
  final system = LocalActorSystem();
  final actor = await system.spawn('counter', () => CounterActor());

  actor.tell(LocalMessage(payload: 'increment'));
  actor.tell(LocalMessage(payload: 'increment'));

  final response = await actor.ask(
    LocalMessage(payload: 'get'),
    Duration(seconds: 1),
  );
  print('Count from ask: ${(response as LocalMessage).payload}');

  await system.shutdown();
}
