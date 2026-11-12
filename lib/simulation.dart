/// Deterministic simulation testing for dactor.
///
/// Runs an actor system on a seeded scheduler with virtual time, so that a
/// test can be repeated under many message orderings and any failure can be
/// replayed exactly from its seed.
library;

export 'src/local_actor_system.dart' show InjectedFault;
export 'src/simulation/simulation.dart';
