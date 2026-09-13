import 'package:dactor/src/actor.dart';
import 'package:dactor/src/actor_ref.dart';
import 'package:dactor/src/local_actor_system.dart';
import 'package:dactor/src/supervision.dart';

class SupervisorActor extends Actor implements Supervisor {
  @override
  final SupervisionStrategy strategy;
  final _children = <String, ActorRef>{};

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
      // Restarts happen in place: the child's ActorRef, mailbox, watchers and
      // subscriptions survive, only the Actor instance is replaced.
      if (strategy.restartAll) {
        // AllForOne: restart every child, failed one first.
        await context.restart(child);
        for (final ref in List.of(_children.values)) {
          if (ref.id != child.id) {
            await context.restart(ref);
          }
        }
      } else {
        // OneForOne: restart only the failed child.
        await context.restart(child);
      }
    } else if (decision == SupervisionDecision.stop) {
      await (context.system as LocalActorSystem).stop(child);
      final childId = _findChildId(child);
      if (childId != null) {
        _children.remove(childId);
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
