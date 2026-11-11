import 'package:dactor/dactor.dart';
import 'package:test/test.dart';

import 'support/supervision_scenarios.dart';

void main() {
  late LocalActorSystem system;
  late SupervisionScenarios scenarios;

  setUp(() async {
    final metrics = InMemoryMetricsCollector();
    system = LocalActorSystem(SupervisionScenarios.config(metrics));
    scenarios = SupervisionScenarios(system, metrics);
    await scenarios.setUp();
  });

  tearDown(() => system.shutdown());

  // The bodies live in support/supervision_scenarios.dart, so that the
  // simulation tests can run the same ones.
  final catalogue = SupervisionScenarios(
      LocalActorSystem.stepped(), InMemoryMetricsCollector());
  final names = catalogue.all.keys;
  for (final name in names) {
    test(name, () => scenarios.all[name]!());
  }
  for (final name in catalogue.concurrent.keys) {
    test(name, () => scenarios.concurrent[name]!());
  }
}
