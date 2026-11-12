import 'dart:async';

import 'package:dactor/src/actor_ref.dart';

/// A zone that can be switched off.
///
/// Everything one actor incarnation does runs inside its own [zone]. While
/// the zone is alive, errors that nothing caught (an unawaited future, a
/// timer callback) are reported to [onUncaughtError] instead of reaching the
/// enclosing zone. After [kill], every callback that would have run in the
/// zone is dropped: code suspended on an `await` never resumes, stream
/// listeners go quiet, and timers are cancelled.
///
/// Two things escape: work the actor started through `Zone.root.run`, and a
/// synchronous stretch of code that is already running when [kill] is called.
///
/// One zone exists per actor, so its footprint matters. The zone handlers are
/// static and shared, and find their [TombstoneZone] through an [Expando];
/// giving every zone its own closures and zone-values map costs roughly three
/// times as much memory.
abstract class TombstoneZone {
  static final _byZone = Expando<TombstoneZone>();

  static const _specification = ZoneSpecification(
    handleUncaughtError: _handleUncaughtError,
    run: _run,
    runUnary: _runUnary,
    runBinary: _runBinary,
    createTimer: _createTimer,
    createPeriodicTimer: _createPeriodicTimer,
  );

  late final Zone zone;
  Set<Timer>? _timers;
  Completer<void>? _killed;
  bool _dead = false;

  /// Forks from [parent], which should be the actor system's own zone so that
  /// one actor's zone never wraps another's.
  static const _key = #dactor.actorZone;

  TombstoneZone(Zone parent) {
    zone = parent.fork(specification: _specification, zoneValues: {_key: this});
    _byZone[zone] = this;
  }

  /// The actor whose code is running right now, or null outside any actor.
  static ActorRef? get currentSelf {
    final owner = Zone.current[_key];
    return owner is TombstoneZone ? owner.self : null;
  }

  /// The reference of the actor this zone runs, once it has one.
  ActorRef? get self => null;

  /// The [TombstoneZone] that [zone] is, or is nested inside.
  static TombstoneZone? of(Zone zone) {
    for (Zone? z = zone; z != null; z = z.parent) {
      final found = _byZone[z];
      if (found != null) return found;
    }
    return null;
  }

  /// Called, in [zone], with an error that nothing in the zone caught.
  void onUncaughtError(Object error, StackTrace stackTrace);

  bool get isDead => _dead;

  /// Completes when the zone is killed. Race a future produced inside the
  /// zone against this: once the zone is dead that future never completes.
  Future<void> get killed {
    if (_dead) return Future<void>.value();
    return (_killed ??= Completer<void>()).future;
  }

  /// Runs [f] in the zone. Returns null without running it if the zone is
  /// dead.
  R run<R>(R Function() f) => zone.run(f);

  /// Switches the zone off. Safe to call more than once.
  void kill() {
    if (_dead) return;
    _dead = true;
    final timers = _timers;
    if (timers != null) {
      for (final timer in timers) {
        timer.cancel();
      }
      _timers = null;
    }
    _killed?.complete();
  }

  static void _handleUncaughtError(Zone self, ZoneDelegate parent, Zone zone,
      Object error, StackTrace stackTrace) {
    final owner = _byZone[self]!;
    if (!owner._dead) owner.onUncaughtError(error, stackTrace);
  }

  static R _run<R>(Zone self, ZoneDelegate parent, Zone zone, R Function() f) {
    if (_byZone[self]!._dead) return null as R;
    return parent.run(zone, f);
  }

  static R _runUnary<R, T>(
      Zone self, ZoneDelegate parent, Zone zone, R Function(T) f, T arg) {
    if (_byZone[self]!._dead) return null as R;
    return parent.runUnary(zone, f, arg);
  }

  static R _runBinary<R, T1, T2>(Zone self, ZoneDelegate parent, Zone zone,
      R Function(T1, T2) f, T1 a, T2 b) {
    if (_byZone[self]!._dead) return null as R;
    return parent.runBinary(zone, f, a, b);
  }

  static Timer _createTimer(Zone self, ZoneDelegate parent, Zone zone,
      Duration duration, void Function() f) {
    final owner = _byZone[self]!;
    final timers = owner._timers ??= {};
    late final Timer timer;
    timer = parent.createTimer(zone, duration, () {
      timers.remove(timer);
      f();
    });
    timers.add(timer);
    return timer;
  }

  static Timer _createPeriodicTimer(Zone self, ZoneDelegate parent, Zone zone,
      Duration period, void Function(Timer) f) {
    final timer = parent.createPeriodicTimer(zone, period, f);
    (_byZone[self]!._timers ??= {}).add(timer);
    return timer;
  }
}
