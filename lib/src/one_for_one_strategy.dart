import 'package:dactor/src/supervision.dart';

class OneForOneStrategy implements SupervisionStrategy {
  final SupervisionDecision Function(Object, StackTrace) _decider;
  final int _maxRetries;
  final Duration? _within;
  final _retries = <String, int>{};
  final _timestamps = <String, DateTime>{};

  OneForOneStrategy({
    required SupervisionDecision Function(Object, StackTrace) decider,
    int maxRetries = 10,
    Duration? within,
  })  : _decider = decider,
        _maxRetries = maxRetries,
        _within = within;

  @override
  SupervisionDecision handle(Object error, StackTrace stackTrace) {
    final now = DateTime.now();
    final actorId = stackTrace.toString(); // A bit of a hack to get a unique id

    if (_within != null) {
      final lastRetry = _timestamps[actorId];
      if (lastRetry != null && now.difference(lastRetry) > _within!) {
        _retries[actorId] = 0;
      }
    }

    final retryCount = _retries[actorId] ?? 0;
    if (retryCount >= _maxRetries) {
      return SupervisionDecision.stop;
    }

    final decision = _decider(error, stackTrace);
    if (decision == SupervisionDecision.restart) {
      _retries[actorId] = retryCount + 1;
      _timestamps[actorId] = now;
    }

    return decision;
  }
}
