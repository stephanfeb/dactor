import 'dart:async';

import 'package:dactor/src/actor.dart';
import 'package:dactor/src/actor_ref.dart';
import 'package:dactor/src/local_actor_system.dart';
import 'package:dactor/src/routing/pool.dart';
import 'package:dactor/src/one_for_one_strategy.dart';
import 'package:dactor/src/supervision.dart';
import 'package:dactor/src/supervisor_actor.dart';

/// Supervises a pool's workers and hands each message to one of them.
///
/// In a [LocalActorSystem] a message told to the pool goes straight to a
/// worker without passing through the router's mailbox; the router handles a
/// message itself only while that shortcut is off (see
/// [LocalActorSystem.routeDirectly]).
class RouterActor extends SupervisorActor {
  final Pool _pool;
  final Actor Function() _workerFactory;
  final _workers = <ActorRef>[];

  RouterActor(this._pool, this._workerFactory)
      : super(OneForOneStrategy(decider: (error, stackTrace) {
          return SupervisionDecision.restart;
        }));

  @override
  Future<void> preStart() async {
    super.preStart();
    for (var i = 0; i < _pool.workerCount; i++) {
      _workers.add(await supervise('worker-$i', _workerFactory));
    }
    if (context.system case final LocalActorSystem system) {
      system.routeDirectly(context.self, _pick);
    }
  }

  @override
  void postStop() {
    if (context.system case final LocalActorSystem system) {
      system.routeDirectly(context.self, null);
    }
    super.postStop();
  }

  /// The worker for [message], or null if it is not alive.
  ActorRef? _pick(Object? message) {
    if (_workers.isEmpty) return null;
    final worker = _workers[_pool.logic.select(_workers.length, message)];
    return worker.isAlive ? worker : null;
  }

  @override
  Future<void> onMessage(dynamic message) async {
    if (_workers.isEmpty) return;
    context.forward(
        _workers[_pool.logic.select(_workers.length, message)], message);
  }
}
