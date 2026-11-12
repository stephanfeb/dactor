// Imports only the public barrel on purpose: this file also checks that the
// observability types are reachable without `package:dactor/src/...`.
import 'package:dactor/dactor.dart';
import 'package:test/test.dart';

class _Echo extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {
    context.sender?.tell(LocalMessage(payload: message));
  }
}

class _Ref implements ActorRef {
  @override
  final String id = 'x';
  @override
  bool get isAlive => true;
  @override
  void tell(Message message, {ActorRef? sender}) {}
  @override
  Future<T> ask<T>(Message message, [Duration? timeout]) =>
      throw UnimplementedError();
  @override
  void watch(ActorRef watcher) {}

  @override
  void unwatch(ActorRef watcher) {}
}

TraceEvent _event(String id) => TraceEvent(id, 'sent', _Ref(), 'payload-$id');

void main() {
  group('defaults', () {
    test('a system built without config collects nothing', () async {
      final system = LocalActorSystem();
      expect(system.metrics, isA<NoOpMetricsCollector>());
      expect(system.tracer, isA<NoOpTraceCollector>());
      expect(system.logger, isA<ConsoleLogCollector>());

      final ref = await system.spawn('echo', () => _Echo());
      for (var i = 0; i < 1000; i++) {
        ref.tell(LocalMessage(payload: i));
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await system.shutdown();
    });

    test('explicit collectors are still honoured', () async {
      final metrics = InMemoryMetricsCollector();
      final tracer = InMemoryTraceCollector();
      final system = LocalActorSystem(
          ActorSystemConfig(metricsCollector: metrics, traceCollector: tracer));
      final ref = await system.spawn('echo', () => _Echo());
      final reply = await ref.ask<dynamic>(LocalMessage(payload: 'hi'));
      expect(reply, 'hi');
      expect(metrics.getCounter('messages.processed'), greaterThan(0));
      expect(tracer.eventCount, greaterThan(0));
      await system.shutdown();
    });

    test('the barrel exports the types a config needs', () {
      // Compiles only if every one of these is exported from dactor.dart.
      ActorSystemConfig(
        metricsCollector: const NoOpMetricsCollector(),
        traceCollector: const NoOpTraceCollector(),
        logCollector: const NoOpLogCollector(),
      );
      Pool(workerCount: 1, logic: RoundRobinRoutingLogic());
      LogRecord(LogLevel.info, 'reachable');
    });
  });

  group('InMemoryTraceCollector', () {
    test('evicts the oldest correlation ids past maxEvents', () {
      final collector = InMemoryTraceCollector(maxEvents: 5);
      for (var i = 0; i < 4; i++) {
        collector.record(_event('a'));
      }
      collector.record(_event('b'));
      expect(collector.eventCount, 5);
      expect(collector.traces.keys, ['a', 'b']);

      // One more event: 'a' (4 events, oldest) is dropped as a whole.
      collector.record(_event('c'));
      expect(collector.traces.keys, ['b', 'c']);
      expect(collector.eventCount, 2);
    });

    test('never retains more than maxEvents', () {
      final collector = InMemoryTraceCollector(maxEvents: 100);
      for (var i = 0; i < 10000; i++) {
        collector.record(_event('id-$i'));
      }
      expect(collector.eventCount, 100);
      expect(collector.traces.length, 100);
      expect(collector.traces.keys.first, 'id-9900');
    });

    test('traces view is read-only and clear() empties it', () {
      final collector = InMemoryTraceCollector();
      collector.record(_event('a'));
      expect(() => collector.traces.remove('a'), throwsUnsupportedError);
      collector.clear();
      expect(collector.eventCount, 0);
      expect(collector.traces, isEmpty);
    });

    test('rejects a non-positive limit', () {
      expect(() => InMemoryTraceCollector(maxEvents: 0), throwsArgumentError);
    });
  });

  group('InMemoryMetricsCollector', () {
    test('keeps only the most recent maxTimings samples per name', () {
      final metrics = InMemoryMetricsCollector(maxTimings: 3);
      for (var i = 1; i <= 5; i++) {
        metrics.timing('t', Duration(milliseconds: i));
      }
      expect(metrics.getTimings('t').map((d) => d.inMilliseconds), [3, 4, 5]);
      expect(metrics.getTimings('other'), isEmpty);
    });

    test('counters and gauges are unaffected by the timing bound', () {
      final metrics = InMemoryMetricsCollector(maxTimings: 1);
      metrics.increment('c', count: 3);
      metrics.decrement('c');
      metrics.gauge('g', 2.5);
      expect(metrics.getCounter('c'), 2);
      expect(metrics.getGauge('g'), 2.5);
    });
  });
}
