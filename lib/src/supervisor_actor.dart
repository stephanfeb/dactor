import 'package:dactor/src/actor.dart';
import 'package:dactor/src/actor_ref.dart';
import 'package:dactor/src/exit_reason.dart';
import 'package:dactor/src/mailbox_config.dart';
import 'package:dactor/src/local_actor_system.dart';
import 'package:dactor/src/supervision.dart';

/// A supervisor: an actor whose job is to start children, watch them, and
/// act when one fails or disappears.
///
/// Create the children in `preStart` (with [supervise], [startChild] or
/// [startChildren]) so that they come back when the supervisor itself is
/// restarted.
///
/// The [strategy] decides what happens to a child that fails. It also sets a
/// restart budget for the supervisor as a whole: more than
/// [SupervisionStrategy.maxRestarts] restarts within
/// [SupervisionStrategy.period], across all children, and the supervisor
/// gives up. It fails with [RestartLimitExceeded], its children are stopped
/// with it, and its own supervisor takes over.
class SupervisorActor extends Actor implements Supervisor {
  @override
  final SupervisionStrategy strategy;

  /// The children this supervisor is responsible for, in start order.
  final _specs = <String, ChildSpec>{};

  /// Ids of children this supervisor is stopping on purpose, so that their
  /// exit is not mistaken for one that calls for a restart.
  final _expectedExits = <String>{};

  late final RestartBudget _budget =
      RestartBudget(strategy.maxRestarts, strategy.period);

  SupervisorActor(this.strategy);

  @override
  Future<void> onMessage(dynamic message) async {
    // Supervisors typically don't handle regular messages
  }

  LocalActorSystem get _system => context.system as LocalActorSystem;

  /// Starts a child and takes responsibility for it.
  @override
  Future<ActorRef> supervise<T extends Actor>(
    String id,
    T Function() actorFactory, {
    RestartType restart = RestartType.permanent,
    Duration? shutdown,
    MailboxConfig? mailbox,
  }) {
    return startChild(ChildSpec(id, actorFactory,
        restart: restart, shutdown: shutdown, mailbox: mailbox));
  }

  /// Starts the child described by [spec] and takes responsibility for it.
  Future<ActorRef> startChild(ChildSpec spec) async {
    final replaced = _specs[spec.id];
    _specs[spec.id] = spec;
    try {
      return await _start(spec);
    } catch (_) {
      if (replaced == null) {
        _specs.remove(spec.id);
      } else {
        _specs[spec.id] = replaced;
      }
      rethrow;
    }
  }

  /// Starts [specs] one after the other, in order.
  Future<void> startChildren(Iterable<ChildSpec> specs) async {
    for (final spec in specs) {
      await startChild(spec);
    }
  }

  /// Stops the child named [id] and forgets it. It is not started again,
  /// whatever its [RestartType].
  Future<void> terminateChild(String id) async {
    _specs.remove(id);
    final child = _system.getActor(_childId(id));
    if (child != null) {
      _expectedExits.add(child.id);
      await _system.stopChild(child);
    }
  }

  /// The children this supervisor currently has, in start order.
  List<ActorRef> get supervisedChildren => _system.childrenOf(context.self.id);

  Future<ActorRef> _start(ChildSpec spec) {
    return _system.spawnChild(
      context.self.id,
      spec.id,
      spec.start,
      supervision: strategy,
      stopTimeout: spec.shutdown,
      mailbox: spec.mailbox,
    );
  }

  String _childId(String name) => '${context.self.id}/$name';

  String _nameOf(ActorRef child) =>
      child.id.substring(context.self.id.length + 1);

  /// Counts one restart against the budget, and gives up if that is one too
  /// many.
  void _countRestart(String childId, Object cause) {
    if (!_budget.record()) {
      throw RestartLimitExceeded(context.self.id, childId, cause,
          strategy.maxRestarts, strategy.period);
    }
  }

  @override
  Future<SupervisionDecision> onChildFailure(
    ActorRef child,
    Object error,
    StackTrace stackTrace,
  ) async {
    final name = _nameOf(child);
    var decision = strategy.handle(child.id, error, stackTrace);
    if (decision == SupervisionDecision.restart &&
        _specs[name]?.restart == RestartType.temporary) {
      decision = SupervisionDecision.stop;
    }

    switch (decision) {
      case SupervisionDecision.restart:
        _countRestart(child.id, error);
        // Restarts happen in place: each child's ActorRef, mailbox, watchers
        // and subscriptions survive, only the Actor instance is replaced.
        // The failed child goes first.
        final siblings = supervisedChildren;
        final others = switch (strategy.scope) {
          RestartScope.one => const <ActorRef>[],
          RestartScope.all => siblings.where((ref) => ref.id != child.id),
          RestartScope.rest =>
            siblings.skipWhile((ref) => ref.id != child.id).skip(1),
        };
        await context.restart(child);
        for (final ref in others.toList()) {
          await context.restart(ref);
        }
      case SupervisionDecision.stop:
        _specs.remove(name);
        _expectedExits.add(child.id);
        await _system.stopChild(child);
      case SupervisionDecision.resume:
      case SupervisionDecision.escalate:
        // resume: the child carries on with its state. escalate: the system
        // treats this supervisor as failed and asks its own parent.
        break;
    }
    return decision;
  }

  @override
  Future<void> onChildExited(ActorRef child, ExitReason reason) async {
    if (_expectedExits.remove(child.id)) {
      return;
    }
    final name = _nameOf(child);
    final spec = _specs[name];
    if (spec == null) {
      return;
    }
    final startAgain = switch (spec.restart) {
      RestartType.permanent => true,
      RestartType.transient => reason is! NormalExit && reason is! ShutdownExit,
      RestartType.temporary => false,
    };
    if (!startAgain) {
      _specs.remove(name);
      return;
    }
    // The old actor is gone, so this is a new one under the same id. Keep
    // trying until it starts or the budget runs out.
    Object cause = reason;
    while (true) {
      _countRestart(child.id, cause);
      try {
        await _start(spec);
        return;
      } catch (e) {
        cause = e;
      }
    }
  }
}
