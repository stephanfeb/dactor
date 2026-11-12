import 'dart:async';

import 'package:dactor/src/actor_ref.dart';
import 'package:dactor/src/actor_system.dart';
import 'package:dactor/src/exit_reason.dart';
import 'package:dactor/src/local_message.dart';
import 'package:dactor/src/system_messages.dart';

/// What happens when an application's root actor ends without the
/// controller having stopped it (after Erlang's application restart types).
///
/// In every case the application stops being running, the applications
/// that depend on it are stopped, and an [ApplicationExit] is reported.
enum ApplicationRestart {
  /// Nothing more.
  temporary,

  /// If the root ended abnormally, every application the controller runs
  /// is stopped.
  transient,

  /// However the root ended, every application the controller runs is
  /// stopped.
  permanent,
}

/// An application whose root actor ended without being stopped.
final class ApplicationExit {
  final String name;
  final ExitReason reason;

  /// Whether the controller stopped every application because of it.
  final bool stoppedAll;

  const ApplicationExit(this.name, this.reason, {required this.stoppedAll});

  @override
  String toString() => 'ApplicationExit($name, $reason'
      '${stoppedAll ? ', stopped all' : ''})';
}

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

  /// What the controller does if the root actor ends on its own.
  ApplicationRestart get restart => ApplicationRestart.temporary;

  /// Starts the application and returns its root actor, normally a
  /// supervisor. The application is running for as long as that actor is:
  /// if it ends without the controller stopping it, see [restart].
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
  final _RootWatcher watcher;
  _Running(this.app, this.root, this.watcher);
}

/// Told when a root actor ends.
class _RootWatcher implements ActorRef {
  final ApplicationController _controller;
  final String _name;
  _RootWatcher(this._controller, this._name);

  @override
  String get id => '\$app/$_name';

  @override
  bool get isAlive => true;

  @override
  void tell(Object? message) {
    final payload = unwrapLegacy(message);
    if (payload is Terminated) {
      _controller._rootEnded(_name, payload.actor, payload.reason);
    }
  }

  @override
  Future<T> ask<T>(Object? message, [Duration? timeout]) =>
      throw UnsupportedError('Not an actor');

  @override
  void watch(ActorRef watcher) => throw UnsupportedError('Not an actor');

  @override
  void unwatch(ActorRef watcher) {}
}

/// Starts and stops [Application]s on one actor system, in dependency order.
class ApplicationController {
  final ActorSystem system;

  // Insertion order is start order.
  final _running = <String, _Running>{};
  Future<void> _queue = Future<void>.value();
  final _exits = StreamController<ApplicationExit>.broadcast();

  ApplicationController(this.system);

  /// Applications whose root actor ended without being stopped, after the
  /// controller has acted on it (see [ApplicationRestart]).
  Stream<ApplicationExit> get exits => _exits.stream;

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
            final watcher = _RootWatcher(this, next.name);
            _running[next.name] = _Running(next, root, watcher);
            started.add(next.name);
            // After registering: a root that is already dead is reported
            // at once.
            root.watch(watcher);
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
  Future<void> stopAll() => _serial(_stopAll);

  Future<void> _stopAll() async {
    for (final name in _running.keys.toList().reversed) {
      await _stopOne(name);
    }
  }

  Future<void> _stopOne(String name) async {
    final entry = _running.remove(name);
    if (entry == null) return;
    entry.root.unwatch(entry.watcher);
    await system.stop(entry.root);
    await entry.app.stopped();
  }

  /// The root of [name] ended. Unless the controller stopped it (then it is
  /// no longer in [_running]), the application is over.
  void _rootEnded(String name, ActorRef root, ExitReason reason) {
    final entry = _running[name];
    if (entry == null || !identical(entry.root, root)) return;
    unawaited(_serial(() async {
      // Stopped meanwhile by a call queued before this one.
      if (!identical(_running[name]?.root, root)) return;
      _running.remove(name);
      final dependents = <String>{name};
      for (final other in _running.values) {
        if (other.app.dependencies.any((d) => dependents.contains(d.name))) {
          dependents.add(other.app.name);
        }
      }
      for (final each in _running.keys.toList().reversed) {
        if (dependents.contains(each)) await _stopOne(each);
      }
      await entry.app.stopped();
      final stopAll = switch (entry.app.restart) {
        ApplicationRestart.temporary => false,
        ApplicationRestart.transient => !reason.isNormal,
        ApplicationRestart.permanent => true,
      };
      if (stopAll) await _stopAll();
      _exits.add(ApplicationExit(name, reason, stoppedAll: stopAll));
    }));
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
