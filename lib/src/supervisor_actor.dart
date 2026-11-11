import 'package:dactor/src/actor.dart';
import 'package:dactor/src/actor_ref.dart';
import 'package:dactor/src/local_actor_system.dart';
import 'package:dactor/src/supervision.dart';

class SupervisorActor extends Actor implements Supervisor {
  @override
  final SupervisionStrategy strategy;

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
    return _system.spawnChild(
      context.self.id,
      id,
      actorFactory,
      supervision: strategy,
    );
  }

  LocalActorSystem get _system => context.system as LocalActorSystem;

  /// The children this supervisor currently has, in start order.
  List<ActorRef> get supervisedChildren => _system.childrenOf(context.self.id);

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
        for (final ref in supervisedChildren) {
          if (ref.id != child.id) {
            await context.restart(ref);
          }
        }
      } else {
        // OneForOne: restart only the failed child.
        await context.restart(child);
      }
    } else if (decision == SupervisionDecision.stop) {
      await _system.stop(child);
    }
    // resume: the child carries on with its state. escalate: the system
    // treats this supervisor as failed and asks its own parent.
    return decision;
  }
}
