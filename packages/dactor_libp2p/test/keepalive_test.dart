@Timeout(Duration(seconds: 90))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dactor/dactor.dart';
import 'package:dactor_libp2p/dactor_libp2p.dart';
import 'package:dactor_remote/dactor_remote.dart';
import 'package:test/test.dart';

import 'support.dart';

/// A node that vanishes without closing anything (its process is killed;
/// a phone that loses its signal looks the same) is noticed through the
/// muxer's keep-alive.
void main() {
  test('a killed process is noticed after the keep-alive timeout', () async {
    const keepAlive = Duration(milliseconds: 500);
    const keepAliveTimeout = Duration(seconds: 2);
    final process = await Process.start(Platform.resolvedExecutable, [
      'run',
      'test/support/bob_process.dart',
      '${keepAlive.inMilliseconds}',
      '${keepAliveTimeout.inMilliseconds}',
    ]);
    addTearDown(() => process.kill(ProcessSignal.sigkill));
    final lines =
        process.stdout.transform(utf8.decoder).transform(const LineSplitter());
    final iterator = StreamIterator(lines);
    expect(await iterator.moveNext(), isTrue);
    final bobHost = iterator.current;
    expect(await iterator.moveNext(), isTrue);
    final bobUri = iterator.current;

    final log = <String>[];
    final system = LocalActorSystem(
        ActorSystemConfig(logCollector: const NoOpLogCollector()));
    final transport = Libp2pTransport(
        await startHost(
            listen: const ['/ip4/127.0.0.1/udp/0/udx'],
            allowLoopback: true,
            keepAlive: keepAlive,
            keepAliveTimeout: keepAliveTimeout),
        closeHost: true);
    await transport.addAddress(bobHost);
    final node = RemoteNode(system, transport, codecs: codecs());
    addTearDown(() async {
      await node.close();
      await system.shutdown();
    });

    final bob = node.resolve(bobUri);
    final alice = await system.spawn('alice', () => Agent('alice', log));
    await alice.ask<String>(LocalMessage(payload: Introduce('bob', bob)));
    expect(await alice.ask<String>(LocalMessage(payload: ('ask', 'bob'))),
        'relayed: pong from bob');
    await alice.ask<String>(LocalMessage(payload: ('watch', 'bob')));
    await Future<void>.delayed(const Duration(milliseconds: 200));

    final watch = Stopwatch()..start();
    process.kill(ProcessSignal.sigkill);
    while (!log.any((l) => l.endsWith('noconnection')) &&
        watch.elapsed < const Duration(seconds: 60)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    printOnFailure('noticed after ${watch.elapsedMilliseconds} ms');
    expect(log, contains('alice saw ${bob.id} terminated: noconnection'));
    // The timeout plus at most one interval, and some slack; well under
    // UDX's 30 s idle timeout, which would otherwise be what noticed.
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
  });
}
