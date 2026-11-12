import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:dactor_remote/dactor_remote.dart';

void tell(ActorRef ref, Object? payload, {ActorRef? sender}) =>
    ref.tell(LocalMessage(payload: payload), sender: sender);

String describe(ExitReason reason) => switch (reason) {
      NormalExit() => 'normal',
      ShutdownExit() => 'shutdown',
      KilledExit() => 'killed',
      NoProcExit() => 'noproc',
      NoConnectionExit() => 'noconnection',
      ErrorExit(:final error) => switch (error) {
          LinkedActorExited(:final from, :final reason) =>
            'linked(${from.id}, ${describe(reason)})',
          _ => 'error($error)',
        },
    };

// ---- a small typed protocol with codecs ----

sealed class CounterMsg {}

final class Add extends CounterMsg {
  final int n;
  Add(this.n);
}

final class Get extends CounterMsg with Call<int> {}

final class Fail extends CounterMsg with Call<int> {}

/// Carries a reference inside a message.
final class Introduce {
  final String alias;
  final ActorRef who;
  Introduce(this.alias, this.who);
}

CodecRegistry codecs() => CodecRegistry()
  ..register<Add>('Add', encode: (m, _) => m.n, decode: (d, _) => Add(d as int))
  ..register<Get>('Get', encode: (m, _) => null, decode: (d, _) => Get())
  ..register<Fail>('Fail', encode: (m, _) => null, decode: (d, _) => Fail())
  // Records are not plain values; the commands the agents take are pairs.
  ..register<(String, String)>('Pair',
      encode: (m, _) => [m.$1, m.$2],
      decode: (d, _) {
        final [first as String, second as String] = d as List;
        return (first, second);
      })
  ..register<Introduce>('Introduce',
      encode: (m, ctx) => [m.alias, ctx.encodeRef(m.who)],
      decode: (d, ctx) {
        final [alias as String, who] = d as List;
        return Introduce(alias, ctx.decodeRef(who));
      });

class Counter extends GenServer<int, CounterMsg> {
  final int start;
  Counter([this.start = 0]);

  @override
  int init() => start;

  @override
  int handleCast(CounterMsg message, int state) =>
      message is Add ? state + message.n : state;

  @override
  CallResult<int> handleCall(CounterMsg request, int state, From from) =>
      switch (request) {
        Get() => request.reply(state, state),
        Fail() => throw StateError('told to fail'),
        _ => NoReply(state),
      };
}

/// Does what it is told and reports what happens to it, into [log].
class Agent extends Actor {
  final String name;
  final List<String> log;
  final bool trap;
  final known = <String, ActorRef>{};
  Agent(this.name, this.log, {this.trap = false});

  @override
  void preStart() {
    context.trapExits = trap;
    log.add('$name started');
  }

  @override
  Future<void> onMessage(dynamic message) async {
    switch (message) {
      case 'ping':
        context.sender?.tell(LocalMessage(payload: 'pong from $name'),
            sender: context.self);
      case String text when text.startsWith('pong'):
        log.add('$name got $text');
      case Introduce(:final alias, :final who):
        known[alias] = who;
        context.sender?.tell(LocalMessage(payload: 'met $alias'));
      case ('ping', String who):
        known[who]!.tell(LocalMessage(payload: 'ping'), sender: context.self);
      case ('ask', String who):
        final answer =
            await known[who]!.ask<String>(LocalMessage(payload: 'ping'));
        context.sender?.tell(LocalMessage(payload: 'relayed: $answer'));
      case ('watch', String who):
        context.watch(known[who]!);
        context.sender?.tell(LocalMessage(payload: 'watching'));
      case ('unwatch', String who):
        context.unwatch(known[who]!);
        context.sender?.tell(LocalMessage(payload: 'unwatched'));
      case ('link', String who):
        context.link(known[who]!);
        context.sender?.tell(LocalMessage(payload: 'linked'));
      case ('unlink', String who):
        context.unlink(known[who]!);
        context.sender?.tell(LocalMessage(payload: 'unlinked'));
      case ('forward', String who, Object? payload):
        // The original sender stays the sender.
        known[who]!
            .tell(LocalMessage(payload: payload), sender: context.sender);
      case 'boom':
        throw StateError('boom in $name');
      case 'sync':
        context.sender?.tell(LocalMessage(payload: 'synced'));
      case Terminated(:final actor, :final reason):
        log.add('$name saw ${actor.id} terminated: ${describe(reason)}');
      case ExitSignal(:final from, :final reason):
        log.add('$name got exit from ${from.id}: ${describe(reason)}');
      default:
        log.add('$name got $message');
    }
  }

  @override
  void postStop() => log.add('$name stopped');
}

SupervisionDecision restart(Object e, StackTrace s) =>
    SupervisionDecision.restart;

/// One node of a test: a system, its remote node, and a way to stop both.
class TestNode {
  final LocalActorSystem system;
  final RemoteNode remote;
  TestNode(this.system, this.remote);

  String get id => remote.id;

  Future<void> close() async {
    await remote.close();
    await system.shutdown();
  }
}

TestNode join(InMemoryNetwork network, String name,
        {LocalActorSystem? system, bool requireCapabilities = true}) =>
    TestNode(
        system ??= LocalActorSystem(
            ActorSystemConfig(logCollector: const NoOpLogCollector())),
        RemoteNode(system, network.join(name),
            codecs: codecs(), requireCapabilities: requireCapabilities));
