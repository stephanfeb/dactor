import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:test/test.dart';

final _log = <String>[];

class Idle extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {
    if (message == 'crash') throw StateError('crashed');
  }
}

class App extends Application {
  @override
  final String name;
  final List<Application> Function() deps;
  final bool fail;
  @override
  final ApplicationRestart restart;
  App(this.name,
      {List<Application> Function()? deps,
      this.fail = false,
      this.restart = ApplicationRestart.temporary})
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

  group('a root that ends by itself', () {
    late List<ApplicationExit> exits;
    setUp(() => exits = []);

    Future<void> watchExits() async {
      apps.exits.listen(exits.add);
    }

    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 50));

    test('temporary: it and its dependents stop, the rest runs on', () async {
      await watchExits();
      final log = App('log');
      final db = App('db', deps: () => [log]);
      final web = App('web', deps: () => [db]);
      final other = App('other');
      await apps.start(web);
      await apps.start(other);
      _log.clear();
      apps.rootOf('db')!.tell('crash');
      await settle();
      expect(apps.running, ['log', 'other']);
      expect(_log, ['stopped web', 'stopped db']);
      expect(exits.single.name, 'db');
      expect(exits.single.reason, isA<ErrorExit>());
      expect(exits.single.stoppedAll, isFalse);
    });

    test('transient: a normal end stops only it', () async {
      await watchExits();
      await apps.start(App('a', restart: ApplicationRestart.transient));
      await apps.start(App('b'));
      await system.stop(apps.rootOf('a')!);
      await settle();
      expect(apps.running, ['b']);
      expect(exits.single.reason, isA<NormalExit>());
      expect(exits.single.stoppedAll, isFalse);
    });

    test('transient: an abnormal end stops everything', () async {
      await watchExits();
      await apps.start(App('a', restart: ApplicationRestart.transient));
      await apps.start(App('b'));
      final b = apps.rootOf('b')!;
      apps.rootOf('a')!.tell('crash');
      await settle();
      expect(apps.running, isEmpty);
      expect(b.isAlive, isFalse);
      expect(exits.single.stoppedAll, isTrue);
    });

    test('permanent: even a normal end stops everything', () async {
      await watchExits();
      await apps.start(App('b'));
      await apps.start(App('a', restart: ApplicationRestart.permanent));
      await system.stop(apps.rootOf('a')!);
      await settle();
      expect(apps.running, isEmpty);
      expect(_log, contains('stopped b'));
      expect(exits.single.stoppedAll, isTrue);
    });

    test('stopping through the controller is not reported', () async {
      await watchExits();
      await apps.start(App('a', restart: ApplicationRestart.permanent));
      await apps.start(App('b'));
      await apps.stop('a');
      await apps.stopAll();
      await settle();
      expect(exits, isEmpty);
    });

    test('a root that is dead on arrival is reported', () async {
      await watchExits();
      final dead = await system.spawn('dead', () => Idle());
      await system.stop(dead);
      await apps.start(_Given('given', dead));
      await settle();
      expect(apps.running, isEmpty);
      expect(exits.single.reason, isA<NoProcExit>());
    });
  });
}

class _Given extends Application {
  @override
  final String name;
  final ActorRef root;
  _Given(this.name, this.root);

  @override
  Future<ActorRef> start(ActorSystem system) async => root;
}
