import 'dart:async';

import 'package:dactor/src/actor_ref.dart';
import 'package:dactor/src/actor_system.dart';

/// A unit of a system that is started and stopped as a whole: a supervision
/// tree with a name and a list of the applications it needs.
abstract class Application {
  const Application();

  /// Identifies the application. Two applications with the same name are
  /// the same application.
  String get name;

  /// Applications that must be running before this one starts. They are
  /// started first, and stopped after it.
  List<Application> get dependencies => const [];

  /// Starts the application and returns its root actor, normally a
  /// supervisor. The application is running for as long as that actor is.
  Future<ActorRef> start(ActorSystem system);

  /// Called after the root actor has stopped.
  FutureOr<void> stopped() {}
}

/// Thrown when applications depend on each other in a circle.
class ApplicationCycleError extends Error {
  /// The names along the circle, ending where it started.
  final List<String> path;
  ApplicationCycleError(this.path);

  @override
  String toString() => 'Applications depend on each other in a circle: '
      '${path.join(' -> ')}';
}

class _Running {
  final Application app;
  final ActorRef root;
  _Running(this.app, this.root);
}

/// Starts and stops [Application]s on one actor system, in dependency order.
class ApplicationController {
  final ActorSystem system;

  // Insertion order is start order.
  final _running = <String, _Running>{};
  Future<void> _queue = Future<void>.value();

  ApplicationController(this.system);

  /// Names of the running applications, in the order they were started.
  List<String> get running => List.unmodifiable(_running.keys);

  bool isRunning(String name) => _running.containsKey(name);

  /// The root actor of a running application, or null.
  ActorRef? rootOf(String name) => _running[name]?.root;

  /// Starts [app] after starting whatever it depends on that is not running
  /// yet. Does nothing if it is already running.
  ///
  /// If an application fails to start, the ones this call had already
  /// started are stopped again, and the error is rethrown.
  Future<void> start(Application app) => _serial(() async {
        final order = <Application>[];
        _plan(app, order, <String>[]);
        final started = <String>[];
        try {
          for (final next in order) {
            if (_running.containsKey(next.name)) continue;
            final root = await next.start(system);
            _running[next.name] = _Running(next, root);
            started.add(next.name);
          }
        } catch (_) {
          for (final name in started.reversed) {
            await _stopOne(name);
          }
          rethrow;
        }
      });

  /// Stops the application called [name], after stopping every running
  /// application that depends on it. Does nothing if it is not running.
  Future<void> stop(String name) => _serial(() async {
        if (!_running.containsKey(name)) return;
        final doomed = <String>{name};
        // Start order puts dependents after what they depend on.
        for (final entry in _running.values) {
          if (entry.app.dependencies.any((d) => doomed.contains(d.name))) {
            doomed.add(entry.app.name);
          }
        }
        for (final each in _running.keys.toList().reversed) {
          if (doomed.contains(each)) await _stopOne(each);
        }
      });

  /// Stops every running application, last started first.
  Future<void> stopAll() => _serial(() async {
        for (final name in _running.keys.toList().reversed) {
          await _stopOne(name);
        }
      });

  Future<void> _stopOne(String name) async {
    final entry = _running.remove(name);
    if (entry == null) return;
    await system.stop(entry.root);
    await entry.app.stopped();
  }

  /// Depth-first, dependencies before dependents.
  void _plan(Application app, List<Application> order, List<String> path) {
    if (path.contains(app.name)) {
      throw ApplicationCycleError(
          [...path.sublist(path.indexOf(app.name)), app.name]);
    }
    if (order.any((planned) => planned.name == app.name)) return;
    path.add(app.name);
    for (final dependency in app.dependencies) {
      _plan(dependency, order, path);
    }
    path.removeLast();
    order.add(app);
  }

  /// One start or stop at a time, in the order they were asked for.
  Future<void> _serial(Future<void> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }
}
