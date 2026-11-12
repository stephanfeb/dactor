import 'package:dactor/src/supervision.dart';

/// Restarts the failed child and every child started after it.
class RestForOneStrategy extends DeciderStrategy {
  const RestForOneStrategy({
    required super.decider,
    super.maxRestarts,
    super.period,
    @Deprecated('Use maxRestarts') super.maxRetries,
    @Deprecated('Use period') super.within,
  });

  @override
  RestartScope get scope => RestartScope.rest;

  @override
  bool get restartAll => scope == RestartScope.all;
}
