@Timeout(Duration(minutes: 5))
library;

import 'package:dactor/dactor.dart';
import 'package:dactor/simulation.dart';
import 'package:test/test.dart';

import 'support/supervision_scenarios.dart';

/// The Phase 1 supervision scenarios, each under many orderings of the
/// simulated scheduler.
void main() {
  const seeds = 1000;
  final catalogue = SupervisionScenarios(
      LocalActorSystem.stepped(), InMemoryMetricsCollector());

  void underSeeds(
      String name, Future<void> Function() Function(SupervisionScenarios) pick,
      {int atLeastOrderings = 1}) {
    test('$name ($seeds seeds)', () {
      late InMemoryMetricsCollector metrics;
      final orderings = <String>{};
      explore((sim) async {
        final scenarios = SupervisionScenarios(sim.system, metrics);
        await scenarios.setUp();
        await pick(scenarios)();
        orderings.add(sim.trace.join('\n'));
      },
          seeds: seeds,
          config: () => SupervisionScenarios.config(
              metrics = InMemoryMetricsCollector()));
      expect(orderings.length, greaterThanOrEqualTo(atLeastOrderings),
          reason: 'the seeds did not explore enough different orderings');
    });
  }

  group('step by step', () {
    // These wait between steps, so there is little for the scheduler to
    // reorder: one or two orderings each.
    for (final name in catalogue.all.keys) {
      if (SupervisionScenarios.realTime.contains(name)) continue;
      underSeeds(name, (s) => s.all[name]!);
    }
  });

  group('concurrent', () {
    for (final name in catalogue.concurrent.keys) {
      underSeeds(name, (s) => s.concurrent[name]!, atLeastOrderings: 3);
    }
  });
}
