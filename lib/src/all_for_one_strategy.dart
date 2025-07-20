import 'package:dactor/src/supervision.dart';

class AllForOneStrategy implements SupervisionStrategy {
  final SupervisionDecision Function(Object, StackTrace) _decider;
  final int _maxRetries;
  final Duration? _within;
  int _retries = 0;
  DateTime? _timestamp;

  AllForOneStrategy({
    required SupervisionDecision Function(Object, StackTrace) decider,
    int maxRetries = 10,
    Duration? within,
  })  : _decider = decider,
        _maxRetries = maxRetries,
        _within = within;

  @override
  SupervisionDecision handle(Object error, StackTrace stackTrace) {
    print('AllForOneStrategy handling error: $error');
    final now = DateTime.now();

    if (_within != null) {
      final lastRetry = _timestamp;
      if (lastRetry != null && now.difference(lastRetry) > _within!) {
        _retries = 0;
      }
    }

    if (_retries >= _maxRetries) {
      print('Max retries reached, stopping actor');
      return SupervisionDecision.stop;
    }

    final decision = _decider(error, stackTrace);
    print('Decider returned: $decision');
    if (decision == SupervisionDecision.restart) {
      _retries++;
      _timestamp = now;
    }

    return decision;
  }
}
