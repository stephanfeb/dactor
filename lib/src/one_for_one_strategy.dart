import 'package:dactor/src/supervision.dart';

/// Restarts only the child that failed.
class OneForOneStrategy extends DeciderStrategy {
  const OneForOneStrategy({
    required super.decider,
    super.maxRestarts,
    super.period,
    @Deprecated('Use maxRestarts') super.maxRetries,
    @Deprecated('Use period') super.within,
  });

  @override
  RestartScope get scope => RestartScope.one;

  @override
  bool get restartAll => scope == RestartScope.all;
}
