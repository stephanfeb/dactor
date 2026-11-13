import 'package:dactor/src/clock.dart';
import 'package:meta/meta.dart';

import 'package:dactor/src/actor.dart';
import 'package:dactor/src/actor_ref.dart';
import 'package:dactor/src/exit_reason.dart';
import 'package:dactor/src/mailbox_config.dart';

/// The decision made by a supervisor when a child actor fails.
enum SupervisionDecision { resume, restart, stop, escalate }

/// Which children a restart decision applies to.
enum RestartScope {
  /// Only the child that failed.
  one,

  /// Every child of the supervisor.
  all,

  /// The child that failed and every child started after it.
  rest,
}

/// When a supervisor starts a child again.
enum RestartType {
  /// Always: after a failure, and also if the child stops for any other
  /// reason the supervisor did not ask for.
  permanent,

  /// After a failure or a kill, but not after a normal stop or a shutdown.
  transient,

  /// Never. A temporary child that fails is stopped and forgotten.
  temporary,
}

/// How a supervisor starts and treats one child.
class ChildSpec {
  /// The child's name under its supervisor: a single path segment.
  final String id;

  /// Creates the actor, for the first start and for every restart.
  final Actor Function() start;

  final RestartType restart;

  /// How long a stop or restart waits for the child's handler in flight.
  /// Null uses [ActorSystemConfig.stopTimeout]; [Duration.zero] does not
  /// wait at all.
  final Duration? shutdown;

  /// The child's mailbox. Null uses [ActorSystemConfig.mailbox].
  final MailboxConfig? mailbox;

  const ChildSpec(
    this.id,
    this.start, {
    this.restart = RestartType.permanent,
    this.shutdown,
    this.mailbox,
  });
}

/// A supervisor restarted its children more often than its strategy allows
/// and has given up. The supervisor fails with this error, so its own
/// supervisor decides what happens next.
class RestartLimitExceeded implements Exception {
  /// The supervisor that gave up, or the top-level actor that ran out.
  final String supervisorId;

  /// The child whose restart went over the limit.
  final String childId;

  /// The failure or exit that asked for that restart.
  final Object cause;

  final int maxRestarts;
  final Duration? period;

  const RestartLimitExceeded(this.supervisorId, this.childId, this.cause,
      this.maxRestarts, this.period);

  @override
  String toString() {
    final window = period == null ? '' : ' within ${period!.inMilliseconds} ms';
    return '$supervisorId exceeded $maxRestarts restarts$window '
        '(last: $childId, $cause)';
  }
}

/// Counts restarts against a limit of [maxRestarts] within [period].
@internal
class RestartBudget {
  final int maxRestarts;
  final Duration? period;
  final _restarts = <int>[];

  RestartBudget(this.maxRestarts, this.period);

  /// Records one restart. Returns false if that takes the count over the
  /// limit.
  bool record() {
    final now = monotonicMicros();
    final window = period;
    if (window != null) {
      final cutoff = now - window.inMicroseconds;
      _restarts.removeWhere((at) => at < cutoff);
    }
    _restarts.add(now);
    return _restarts.length <= maxRestarts;
  }
}

/// A strategy for supervising child actors. Strategies hold no state, so one
/// instance can be shared between supervisors.
abstract class SupervisionStrategy {
  const SupervisionStrategy();

  /// Whether a restart decision applies to all children (true) or just the
  /// failed child (false). Prefer [scope].
  bool get restartAll => false;

  /// Which children a restart decision applies to.
  RestartScope get scope => restartAll ? RestartScope.all : RestartScope.one;

  /// How many restarts the supervisor performs within [period] before it
  /// gives up and fails with [RestartLimitExceeded]. The count covers all of
  /// the supervisor's children together.
  int get maxRestarts => 10;

  /// The window [maxRestarts] is counted over. Null counts over the
  /// supervisor's whole life.
  Duration? get period => const Duration(seconds: 5);

  /// Decides what to do when a child actor fails.
  SupervisionDecision handle(
      String actorId, Object error, StackTrace stackTrace);
}

/// A [SupervisionStrategy] whose decision comes from a function of the error.
abstract class DeciderStrategy extends SupervisionStrategy {
  final SupervisionDecision Function(Object error, StackTrace stackTrace)
      decider;

  @override
  final int maxRestarts;

  @override
  final Duration? period;

  /// [maxRetries] and [within] are the former names of [maxRestarts] and
  /// [period].
  const DeciderStrategy({
    required this.decider,
    int? maxRestarts,
    Duration? period,
    @Deprecated('Use maxRestarts') int? maxRetries,
    @Deprecated('Use period') Duration? within,
  })  : maxRestarts = maxRestarts ?? maxRetries ?? 10,
        period = period ?? within ?? const Duration(seconds: 5);

  @override
  SupervisionDecision handle(
          String actorId, Object error, StackTrace stackTrace) =>
      decider(error, stackTrace);
}

/// A supervisor is an actor that supervises other actors.
abstract class Supervisor extends Actor {
  /// The supervision strategy to use.
  SupervisionStrategy get strategy;

  /// Supervises a new child actor.
  Future<ActorRef> supervise<T extends Actor>(
    String id,
    T Function() actorFactory,
  );

  /// Called when a child actor fails, as one of this supervisor's own
  /// messages: never at the same time as `onMessage` or another call of this.
  /// The child receives nothing until this returns.
  @protected
  Future<SupervisionDecision> onChildFailure(
    ActorRef child,
    Object error,
    StackTrace stackTrace,
  );

  /// Called when a child is gone for good, for whatever [reason], unless
  /// this supervisor is itself stopping or restarting. Runs as one of this
  /// supervisor's own messages.
  @protected
  Future<void> onChildExited(ActorRef child, ExitReason reason) async {}
}
