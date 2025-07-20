import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:dactor/src/local_actor_system.dart';

class TestActorSystem extends LocalActorSystem {
  int _probeCounter = 0;

  TestActorSystem([ActorSystemConfig? config]) : super(config);

  Future<TestProbe> createProbe() async {
    final probeName = 'probe-${_probeCounter++}';
    final completer = Completer<TestProbe>();

    final actor = TestProbe.withCompleter(completer);
    await spawn(probeName, () => actor);

    return completer.future;
  }
}
