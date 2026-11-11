import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:test/test.dart';

final _log = <String>[];

class Idle extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {}
}

class App extends Application {
  @override
  final String name;
  final List<Application> Function() deps;
  final bool fail;
  App(this.name, {List<Application> Function()? deps, this.fail = false})
      : deps = deps ?? (() => const []);

  @override
  List<Application> get dependencies => deps();

  @override
  Future<ActorRef> start(ActorSystem system) async {
    if (fail) throw StateError('$name cannot start');
    _log.add('start $name');
    return system.spawn('$name-root', () => Idle());
  }

  @override
  void stopped() => _log.add('stopped $name');
}

void main() {
  late LocalActorSystem system;
  late ApplicationController apps;

  setUp(() {
    _log.clear();
    system = LocalActorSystem();
    apps = ApplicationController(system);
  });

  tearDown(() => system.shutdown());

  test('starts dependencies first and each application once', () async {
    final log = App('log');
    final db = App('db', deps: () => [log]);
    final web = App('web', deps: () => [db, log]);
    await apps.start(web);
    await apps.start(db);
    expect(_log, ['start log', 'start db', 'start web']);
    expect(apps.running, ['log', 'db', 'web']);
    expect(apps.rootOf('db')?.isAlive, isTrue);
  });

  test('stopAll stops in reverse order and stops the roots', () async {
    final log = App('log');
    final db = App('db', deps: () => [log]);
    await apps.start(db);
    final root = apps.rootOf('log')!;
    _log.clear();
    await apps.stopAll();
    expect(_log, ['stopped db', 'stopped log']);
    expect(root.isAlive, isFalse);
    expect(apps.running, isEmpty);
  });

  test('stopping an application stops its dependents first', () async {
    final log = App('log');
    final db = App('db', deps: () => [log]);
    final web = App('web', deps: () => [db]);
    final other = App('other');
    await apps.start(web);
    await apps.start(other);
    _log.clear();
    await apps.stop('db');
    expect(_log, ['stopped web', 'stopped db']);
    expect(apps.running, ['log', 'other']);
  });

  test('a failed start rolls back what that call started', () async {
    final log = App('log');
    final db = App('db', deps: () => [log]);
    final web = App('web', deps: () => [db], fail: true);
    await apps.start(log);
    await expectLater(apps.start(web), throwsStateError);
    expect(apps.running, ['log']);
    expect(_log, ['start log', 'start db', 'stopped db']);
  });

  test('a dependency circle is reported', () async {
    late App a;
    final b = App('b', deps: () => [a]);
    a = App('a', deps: () => [b]);
    await expectLater(
        apps.start(a),
        throwsA(isA<ApplicationCycleError>()
            .having((e) => e.path, 'path', ['a', 'b', 'a'])));
  });
}
