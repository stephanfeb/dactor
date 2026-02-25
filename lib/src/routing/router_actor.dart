import 'dart:async';

import 'package:dactor/src/actor.dart';
import 'package:dactor/src/actor_ref.dart';
import 'package:dactor/src/local_message.dart';
import 'package:dactor/src/routing/pool.dart';
import 'package:dactor/src/one_for_one_strategy.dart';
import 'package:dactor/src/supervision.dart';
import 'package:dactor/src/supervisor_actor.dart';

class RouterActor extends SupervisorActor {
  final Pool _pool;
  final Actor Function() _workerFactory;
  final _workers = <ActorRef>[];
  int _nextWorkerIndex = 0;

  RouterActor(this._pool, this._workerFactory)
      : super(OneForOneStrategy(decider: (error, stackTrace) {
          return SupervisionDecision.restart;
        }));

  @override
  Future<void> preStart() async {
    super.preStart();
    for (var i = 0; i < _pool.workerCount; i++) {
      final worker =
          await context.spawn('${context.self.id}/worker-$i', _workerFactory);
      _workers.add(worker);
      context.watch(worker);
    }
  }

  @override
  Future<void> onMessage(dynamic message) async {
    if (_workers.isEmpty) {
      return;
    }

    final worker = _workers[_nextWorkerIndex];
    _nextWorkerIndex = (_nextWorkerIndex + 1) % _workers.length;
    worker.tell(LocalMessage(payload: message), sender: context.sender);
  }

  @override
  Future<SupervisionDecision> onChildFailure(
      ActorRef child, Object error, StackTrace stackTrace) async {
    await context.restart(child);
    return SupervisionDecision.restart;
  }
}
