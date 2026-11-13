import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:test/test.dart';

final _log = <String>[];
var _gate = Completer<void>();

/// Holds its handler on 'block' until [_gate] completes, so that what is
/// told meanwhile waits in the mailbox. Logs everything else.
class Gated extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {
    switch (message) {
      case 'block':
        await _gate.future;
      case Terminated(:final actor):
        _log.add('terminated ${actor.id}');
      case ('watch', ActorRef target):
        context.watch(target);
      default:
        _log.add('$message');
    }
  }
}

class Idle extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {}
}

/// Starts one child with [spec].
class Parent extends SupervisorActor {
  final ChildSpec spec;
  Parent(this.spec)
      : super(
            OneForOneStrategy(decider: (_, __) => SupervisionDecision.restart));

  @override
  Future<void> preStart() async {
    super.preStart();
    await startChild(spec);
  }

  @override
  Future<void> onMessage(dynamic message) async {}
}

void main() {
  late LocalActorSystem system;
  late InMemoryMetricsCollector metrics;

  LocalActorSystem start([MailboxConfig mailbox = MailboxConfig.unbounded]) {
    metrics = InMemoryMetricsCollector();
    return LocalActorSystem(ActorSystemConfig(
        metricsCollector: metrics,
        logCollector: const NoOpLogCollector(),
        mailbox: mailbox));
  }

  setUp(() {
    _log.clear();
    _gate = Completer<void>();
    system = start();
  });

  tearDown(() => system.shutdown());

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 20));

  /// Drains the dead letters and returns their messages.
  List<Object?> deadLetters() => [
        for (DeadLetter? letter;
            (letter = system.deadLetterQueue.dequeue()) != null;)
          letter!.message
      ];

  /// Blocks [ref] in a handler, tells it [messages], then lets it go.
  Future<void> fill(ActorRef ref, List<String> messages) async {
    ref.tell('block');
    await settle();
    messages.forEach(ref.tell);
    _gate.complete();
    await settle();
  }

  test('dropNewest turns the new message away', () async {
    final ref = await system.spawn('a', () => Gated(),
        mailbox: const MailboxConfig(capacity: 2));
    await fill(ref, ['m1', 'm2', 'm3']);
    expect(_log, ['m1', 'm2']);
    expect(deadLetters(), ['m3']);
    expect(metrics.getCounter('mailbox.overflow'), 1);
  });

  test('dropOldest makes room by dropping the oldest', () async {
    final ref = await system.spawn('a', () => Gated(),
        mailbox: const MailboxConfig(
            capacity: 2, overflow: OverflowPolicy.dropOldest));
    await fill(ref, ['m1', 'm2', 'm3']);
    expect(_log, ['m2', 'm3']);
    expect(deadLetters(), ['m1']);
  });

  test('fail drops the message and fails the actor', () async {
    final errors = <Object>[];
    final ref = await system.spawn('a', () => Gated(),
        mailbox:
            const MailboxConfig(capacity: 2, overflow: OverflowPolicy.fail),
        supervision: OneForOneStrategy(decider: (error, _) {
      errors.add(error);
      return SupervisionDecision.resume;
    }));
    await fill(ref, ['m1', 'm2', 'm3']);
    expect(errors, [isA<MailboxOverflow>()]);
    expect(deadLetters(), ['m3']);
    expect(_log, ['m1', 'm2']);
  });

  test('messages from the runtime are always accepted', () async {
    final ref = await system.spawn('a', () => Gated(),
        mailbox: const MailboxConfig(capacity: 1));
    final target = await system.spawn('target', () => Idle());
    ref.tell(('watch', target));
    await settle();
    ref.tell('block');
    await settle();
    ref.tell('m1');
    await system.stop(target);
    ref.tell('m2');
    _gate.complete();
    await settle();
    expect(_log, ['m1', 'terminated target']);
    expect(deadLetters(), ['m2']);
  });

  test('the system default applies, and spawn can override it', () async {
    await system.shutdown();
    system = start(const MailboxConfig(capacity: 1));
    final limited = await system.spawn('limited', () => Gated());
    await fill(limited, ['m1', 'm2']);
    expect(_log, ['m1']);

    _log.clear();
    _gate = Completer<void>();
    final free = await system.spawn('free', () => Gated(),
        mailbox: MailboxConfig.unbounded);
    await fill(free, ['m1', 'm2']);
    expect(_log, ['m1', 'm2']);
  });

  test('a pool gives its workers the mailbox', () async {
    final pool = await system.spawn('p', () => Gated(),
        pool: Pool(workerCount: 1), mailbox: const MailboxConfig(capacity: 1));
    await fill(pool, ['m1', 'm2']);
    expect(_log, ['m1']);
    expect(deadLetters(), ['m2']);
  });

  test('a ChildSpec gives its child the mailbox', () async {
    await system.spawn(
        'parent',
        () => Parent(ChildSpec('child', () => Gated(),
            mailbox: const MailboxConfig(capacity: 1))));
    final child = system.getActor('parent/child')!;
    await fill(child, ['m1', 'm2']);
    expect(_log, ['m1']);
  });
}
