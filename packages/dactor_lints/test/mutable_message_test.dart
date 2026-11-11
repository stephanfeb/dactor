import 'package:dactor_lints/src/mutable_message.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

import 'support.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(MutableMessageTest);
  });
}

@reflectiveTest
class MutableMessageTest extends DactorRuleTest {
  @override
  void setUp() {
    rule = MutableMessage();
    super.setUp();
  }

  Future<void> test_messageClass_nonFinalField() async {
    await expectReported('''
import 'package:dactor/dactor.dart';

class Deposit implements Message {
  final String account;
  int [!amountCents!];
  Deposit(this.account, this.amountCents);
}
''');
  }

  Future<void> test_messageClass_extendsLocalMessage() async {
    await expectReported('''
import 'package:dactor/dactor.dart';

class Reply extends LocalMessage {
  String? [!note!];
}
''');
  }

  Future<void> test_messageClass_allFinal() async {
    await assertNoDiagnostics('''
import 'package:dactor/dactor.dart';

class Deposit implements Message {
  static int created = 0;
  final String account;
  final int amountCents;
  late final String label = '\$account: \$amountCents';
  Deposit(this.account, this.amountCents);
  int get doubled => amountCents * 2;
}
''');
  }

  Future<void> test_payload_classWithNonFinalField() async {
    await expectReported('''
import 'package:dactor/dactor.dart';

class Cart {
  int items = 0;
}

void send(ActorRef ref, Cart cart) {
  ref.tell(LocalMessage(payload: [!cart!]));
}
''');
  }

  Future<void> test_payload_inheritedNonFinalField() async {
    await expectReported('''
import 'package:dactor/dactor.dart';

class Base {
  int counter = 0;
}

class Derived extends Base {
  final String name;
  Derived(this.name);
}

void send(ActorRef ref) {
  ref.tell(LocalMessage(payload: [!Derived('x')!]));
}
''');
  }

  Future<void> test_payload_immutableClass() async {
    await assertNoDiagnostics('''
import 'package:dactor/dactor.dart';

class Point {
  final int x, y;
  const Point(this.x, this.y);
}

enum Colour { red, green }

void send(ActorRef ref) {
  ref.tell(LocalMessage(payload: const Point(1, 2)));
  ref.tell(LocalMessage(payload: Colour.red));
  ref.tell(LocalMessage(payload: 'text'));
  ref.tell(LocalMessage(payload: 42));
  ref.tell(LocalMessage(payload: (1, 'record')));
}
''');
  }

  Future<void> test_payload_actorRefIsFine() async {
    await assertNoDiagnostics('''
import 'package:dactor/dactor.dart';

void send(ActorRef ref, ActorRef other) {
  ref.tell(LocalMessage(payload: other));
}
''');
  }

  Future<void> test_publish_eventWithNonFinalField() async {
    await expectReported('''
import 'package:dactor/dactor.dart';

class PriceChanged {
  double price = 0;
}

class Shop extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {
    context.publish([!PriceChanged()!]);
  }
}
''');
  }

  Future<void> test_actorSendingItselfIsLeftToTheOtherRule() async {
    await assertNoDiagnostics('''
import 'package:dactor/dactor.dart';

class Shy extends Actor {
  int count = 0;

  @override
  Future<void> onMessage(dynamic message) async {
    context.publish(this);
  }
}
''');
  }

  Future<void> test_unrelatedClassIsIgnored() async {
    await assertNoDiagnostics('''
class Counter {
  int value = 0;
}

class Holder {
  final dynamic payload;
  Holder({this.payload});
}

void main() {
  Holder(payload: Counter());
}
''');
  }
}
