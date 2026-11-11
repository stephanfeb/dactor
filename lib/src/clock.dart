import 'dart:async';

import 'package:meta/meta.dart';

/// Zone value under which a simulation provides its virtual clock, as an
/// `int Function()` returning microseconds.
@internal
const Symbol clockKey = #dactor.clock;

final _real = Stopwatch()..start();

/// Microseconds on a clock that only moves forward: the simulation's virtual
/// clock when running inside one, the real one otherwise. Everything in the
/// library that measures how much time has passed reads this.
@internal
int monotonicMicros() {
  final clock = Zone.current[clockKey];
  return clock is int Function() ? clock() : _real.elapsedMicroseconds;
}
