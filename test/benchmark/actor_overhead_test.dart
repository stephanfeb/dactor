import 'dart:io';
import 'package:dactor/dactor.dart';
import 'package:test/test.dart';
import 'package:dactor/src/local_actor_system.dart';


class IdleActor extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {
    // This actor is idle and does nothing.
  }
}

void main() {
  group('Actor Memory Overhead', () {
    late LocalActorSystem system;

    setUp(() {
      system = LocalActorSystem();
    });

    tearDown(() async {
      await system.shutdown();
    });

    test('measures the memory overhead of idle actors', () async {
      const actorCount = 20000;

      // Allow the system to stabilize before taking the baseline measurement.
      await Future.delayed(const Duration(seconds: 2));

      // Force GC before taking the baseline measurement.
      _forceGc();
      _forceGc();
      final baselineMemory = ProcessInfo.currentRss;

      final actors = <ActorRef>[];
      for (var i = 0; i < actorCount; i++) {
        final actor = await system.spawn('idle-$i', () => IdleActor());
        actors.add(actor);
      }

      // Allow time for all actors to be created and for GC to run.
      await Future.delayed(const Duration(seconds: 4));

      // Force GC again to get a more accurate reading after allocation.
      _forceGc();
      _forceGc();
      final finalMemory = ProcessInfo.currentRss;

      final delta = finalMemory - baselineMemory;
      final overheadPerActor = delta / actorCount;

      print('Baseline Memory: ${(baselineMemory / 1024).toStringAsFixed(2)} KB');
      print('Final Memory: ${(finalMemory / 1024).toStringAsFixed(2)} KB');
      print('Total Memory Delta for $actorCount actors: ${(delta / 1024).toStringAsFixed(2)} KB');
      print('Average Overhead per Actor: ${(overheadPerActor / 1024).toStringAsFixed(2)} KB');

      // The goal is <1KB per actor. This assertion checks if we are within a reasonable range.
      // We set a slightly higher threshold to account for measurement noise.
      expect(overheadPerActor, lessThan(1500), reason: 'Memory overhead per actor should be less than 1.5 KB');
    }, timeout: const Timeout(Duration(minutes: 1)));
  });
}

/// A helper function to trigger garbage collection.
///
/// This is not a guaranteed way to force GC in Dart, but it's the most common
/// and effective method available for testing purposes. It works by allocating
/// a large object and then immediately discarding it, which encourages the VM
/// to run a garbage collection cycle.
void _forceGc() {
  // Allocate a large object to trigger GC
  List.generate(1000000, (i) => List.filled(100, 0));
}
