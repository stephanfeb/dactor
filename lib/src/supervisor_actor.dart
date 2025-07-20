import 'package:dactor/src/actor.dart';
import 'package:dactor/src/actor_ref.dart';
import 'package:dactor/src/local_actor_system.dart';
import 'package:dactor/src/message.dart';
import 'package:dactor/src/supervision.dart';

class SupervisorActor extends Actor implements Supervisor {
  @override
  final SupervisionStrategy strategy;
  final _children = <String, ActorRef>{};
  final _childFactories = <String, Function>{};

  SupervisorActor(this.strategy);

  @override
  Future<void> onMessage(dynamic message) async {
    // Supervisors typically don't handle regular messages
  }

  @override
  Future<ActorRef> supervise<T extends Actor>(
    String id,
    T Function() actorFactory,
  ) async {
    print('Supervisor ${context.self.id} supervising new child: $id');
    final actorRef = await (context.system as LocalActorSystem).spawn(
      '${context.self.id}/$id',
      actorFactory,
      supervision: strategy,
    );
    _children[id] = actorRef;
    _childFactories[id] = actorFactory;
    return actorRef;
  }

  @override
  Future<SupervisionDecision> onChildFailure(
    ActorRef child,
    Object error,
    StackTrace stackTrace,
  ) async {
    final decision = strategy.handle(error, stackTrace);
    if (decision == SupervisionDecision.restart) {
      final childrenToRestart = List.of(_children.entries);
      for (final entry in childrenToRestart) {
        final childId = entry.key;
        final childRef = entry.value;
        await (context.system as LocalActorSystem).stop(childRef);
        await supervise(childId, _childFactories[childId]! as Actor Function());
      }
    }
    return decision;
  }
}
