import 'package:dactor_lints/src/captured_actor_state.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

import 'support.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(CapturedActorStateTest);
  });
}

@reflectiveTest
class CapturedActorStateTest extends DactorRuleTest {
  @override
  void setUp() {
    rule = CapturedActorState();
    super.setUp();
  }

  Future<void> test_closureAsPayload() async {
    await expectReported('''
import 'package:dactor/dactor.dart';

class Counter extends Actor {
  int count = 0;
  final ActorRef peer;
  Counter(this.peer);

  @override
  Future<void> onMessage(dynamic message) async {
    peer.tell(LocalMessage(payload: [!() => count++!]));
  }
}
''');
  }

  Future<void> test_closureInsideMessageObject() async {
    await expectReported('''
import 'package:dactor/dactor.dart';

class Job {
  final void Function() onDone;
  const Job(this.onDone);
}

class Boss extends Actor {
  int finished = 0;
  final ActorRef worker;
  Boss(this.worker);

  @override
  Future<void> onMessage(dynamic message) async {
    worker.tell(LocalMessage(payload: Job([!() {
      finished++;
    }!])));
  }
}
''');
  }

  Future<void> test_thisAsPayload() async {
    await expectReported('''
import 'package:dactor/dactor.dart';

class Shy extends Actor {
  final ActorRef peer;
  Shy(this.peer);

  @override
  Future<void> onMessage(dynamic message) async {
    peer.tell(LocalMessage(payload: [!this!]));
  }
}
''');
  }

  Future<void> test_publishedClosure() async {
    await expectReported('''
import 'package:dactor/dactor.dart';

class Loud extends Actor {
  int volume = 11;

  @override
  Future<void> onMessage(dynamic message) async {
    context.publish([!() => volume!]);
  }
}
''');
  }

  Future<void> test_selfRefIsFine() async {
    await assertNoDiagnostics('''
import 'package:dactor/dactor.dart';

class Polite extends Actor {
  final ActorRef peer;
  Polite(this.peer);

  @override
  Future<void> onMessage(dynamic message) async {
    peer.tell(LocalMessage(payload: context.self));
    peer.tell(LocalMessage(payload: 'data', sender: context.self));
  }
}
''');
  }

  Future<void> test_closureOutsideAnActorIsNotThisRulesBusiness() async {
    await assertNoDiagnostics('''
import 'package:dactor/dactor.dart';

void send(ActorRef ref) {
  ref.tell(LocalMessage(payload: () => 1));
}
''');
  }

  Future<void> test_closureNotSent() async {
    await assertNoDiagnostics('''
import 'package:dactor/dactor.dart';

class Fine extends Actor {
  final items = <int>[];

  @override
  Future<void> onMessage(dynamic message) async {
    items.where((i) => i > 0).toList();
  }
}
''');
  }
}
