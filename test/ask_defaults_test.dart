import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:test/test.dart';

class _Silent extends Actor {
  static int received = 0;
  @override
  Future<void> onMessage(dynamic message) async {
    received++;
  }
}

void main() {
  test('AskConfig() does not retry', () {
    expect(AskConfig().enableRetries, isFalse);
    expect(AskConfig.noRetries().enableRetries, isFalse);
  });

  test('presets opt in to retries explicitly', () {
    expect(AskConfig.development().enableRetries, isTrue);
    expect(AskConfig.production().enableRetries, isTrue);
  });

  test('a timed-out ask on defaults delivers the request exactly once',
      () async {
    _Silent.received = 0;
    final system = LocalActorSystem();
    final ref = await system.spawn('silent', () => _Silent());

    final sw = Stopwatch()..start();
    await expectLater(
      ref.ask<dynamic>('ping', const Duration(milliseconds: 50)),
      throwsA(isA<TimeoutException>()
          .having((e) => e.toString(), 'message', contains('attempt 1'))),
    );
    sw.stop();

    expect(_Silent.received, 1, reason: 'no retry may re-send the request');
    expect(sw.elapsedMilliseconds, lessThan(500),
        reason: 'no backoff/retry cycle');
    await system.shutdown();
  });
}
