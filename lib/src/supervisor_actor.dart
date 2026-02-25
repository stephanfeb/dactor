import 'package:dactor/src/actor.dart';
import 'package:dactor/src/actor_ref.dart';
import 'package:dactor/src/local_actor_system.dart';
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
    final decision = strategy.handle(child.id, error, stackTrace);
    if (decision == SupervisionDecision.restart) {
      if (strategy.restartAll) {
        // AllForOne: restart all children
        final childrenToRestart = List.of(_children.entries);
        for (final entry in childrenToRestart) {
          final childId = entry.key;
          await (context.system as LocalActorSystem).stop(entry.value);
          await supervise(childId, _childFactories[childId]! as Actor Function());
        }
      } else {
        // OneForOne: restart only the failed child
        final childId = _findChildId(child);
        if (childId != null) {
          await (context.system as LocalActorSystem).stop(child);
          await supervise(childId, _childFactories[childId]! as Actor Function());
        }
      }
    } else if (decision == SupervisionDecision.stop) {
      await (context.system as LocalActorSystem).stop(child);
      final childId = _findChildId(child);
      if (childId != null) {
        _children.remove(childId);
        _childFactories.remove(childId);
      }
    }
    return decision;
  }

  String? _findChildId(ActorRef child) {
    for (final entry in _children.entries) {
      if (entry.value.id == child.id) return entry.key;
    }
    return null;
  }
}
