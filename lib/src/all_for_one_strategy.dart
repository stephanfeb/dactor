import 'package:dactor/src/supervision.dart';

/// Restarts every child of the supervisor.
class AllForOneStrategy extends DeciderStrategy {
  const AllForOneStrategy({
    required super.decider,
    super.maxRestarts,
    super.period,
    @Deprecated('Use maxRestarts') super.maxRetries,
    @Deprecated('Use period') super.within,
  });

  @override
  RestartScope get scope => RestartScope.all;

  @override
  bool get restartAll => scope == RestartScope.all;
}
