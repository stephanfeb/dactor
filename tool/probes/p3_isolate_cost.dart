// Probe P3 (doc/otp-gap-roadmap.md): what do isolates cost?
//
// Measures, for 1, 100 and 1,000 isolates in one group: time to spawn them
// (until each has answered), resident memory per idle isolate, and time to
// kill them. Then the cost of a message: a round trip through one isolate
// for payloads of several sizes, and throughput of one-way sends.
//
// Run:  dart run tool/probes/p3_isolate_cost.dart
//       dart compile exe tool/probes/p3_isolate_cost.dart -o /tmp/p3 && /tmp/p3
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

/// Answers with its own port, then echoes whatever arrives.
void echo(SendPort home) {
  final inbox = ReceivePort();
  home.send(inbox.sendPort);
  inbox.listen((message) {
    if (message is (SendPort, Object?)) {
      message.$1.send(message.$2);
    }
  });
}

/// Counts messages; answers the count when it sees a SendPort.
void sink(SendPort home) {
  final inbox = ReceivePort();
  home.send(inbox.sendPort);
  var count = 0;
  inbox.listen((message) {
    if (message is SendPort) {
      message.send(count);
    } else {
      count++;
    }
  });
}

final class Order {
  final int id;
  final String customer;
  final List<String> items;
  const Order(this.id, this.customer, this.items);
}

String kb(int bytes) => '${(bytes / 1024).toStringAsFixed(0)} KB';

Future<void> spawnMany(int n) async {
  final before = ProcessInfo.currentRss;
  final watch = Stopwatch()..start();
  final isolates = <Isolate>[];
  final exits = <Future<void>>[];
  final readies = <Future<Object?>>[];
  for (var i = 0; i < n; i++) {
    final ready = ReceivePort();
    final exit = ReceivePort();
    readies.add(ready.first);
    exits.add(exit.first);
    isolates
        .add(await Isolate.spawn(echo, ready.sendPort, onExit: exit.sendPort));
  }
  await Future.wait(readies);
  final spawned = watch.elapsedMicroseconds;
  await Future<void>.delayed(const Duration(milliseconds: 200));
  final after = ProcessInfo.currentRss;

  watch
    ..reset()
    ..start();
  for (final isolate in isolates) {
    isolate.kill(priority: Isolate.immediate);
  }
  await Future.wait(exits);
  final killed = watch.elapsedMicroseconds;

  print('${n.toString().padLeft(5)} isolates: '
      'spawn ${(spawned / 1000).toStringAsFixed(1)} ms total, '
      '${(spawned / n).toStringAsFixed(0)} us each; '
      '${kb((after - before) ~/ n)} RSS each; '
      'kill ${(killed / 1000).toStringAsFixed(1)} ms total');
}

Future<void> roundTrips(String name, Object? payload, {int n = 20000}) async {
  final ready = ReceivePort();
  final isolate = await Isolate.spawn(echo, ready.sendPort);
  final port = await ready.first as SendPort;
  final replies = ReceivePort();
  final queue = StreamIterator(replies);
  // Warm up.
  for (var i = 0; i < 2000; i++) {
    port.send((replies.sendPort, payload));
    await queue.moveNext();
  }
  final watch = Stopwatch()..start();
  for (var i = 0; i < n; i++) {
    port.send((replies.sendPort, payload));
    await queue.moveNext();
  }
  final micros = watch.elapsedMicroseconds / n;
  replies.close();
  isolate.kill(priority: Isolate.immediate);
  print('  ${name.padRight(34)} ${micros.toStringAsFixed(1).padLeft(8)} us '
      'per round trip');
}

Future<void> oneWay(String name, Object? payload, {int n = 200000}) async {
  final ready = ReceivePort();
  final isolate = await Isolate.spawn(sink, ready.sendPort);
  final port = await ready.first as SendPort;
  final done = ReceivePort();
  final watch = Stopwatch()..start();
  for (var i = 0; i < n; i++) {
    port.send(payload);
  }
  final sent = watch.elapsedMicroseconds;
  port.send(done.sendPort);
  await done.first;
  final total = watch.elapsedMicroseconds;
  isolate.kill(priority: Isolate.immediate);
  print('  ${name.padRight(34)} '
      '${(n / total * 1e6 / 1000).toStringAsFixed(0).padLeft(8)} k msg/s '
      '(send side alone ${(sent / n).toStringAsFixed(2)} us each)');
}

Future<void> main() async {
  final aot = !Platform.executable.endsWith('dart');
  print('Dart ${Platform.version.split(' ').first}, '
      '${aot ? 'AOT' : 'JIT'}, ${Platform.operatingSystem}, '
      '${Platform.numberOfProcessors} cores\n');

  for (final n in [1, 100, 1000]) {
    await spawnMany(n);
  }

  final order = Order(42, 'Ada', ['tea', 'biscuits', 'jam']);
  final map = {for (var i = 0; i < 50; i++) 'key$i': i};
  final bigList = List<int>.generate(100000, (i) => i);
  final bytes = Uint8List(1 << 20);
  final transferable = TransferableTypedData.fromList([Uint8List(1 << 20)]);

  print('\nRound trip through one isolate:');
  await roundTrips('int', 7);
  await roundTrips('short string', 'hello');
  await roundTrips('const object', const Order(1, 'x', []));
  await roundTrips('small object (3 fields, list)', order);
  await roundTrips('map of 50 entries', map);
  await roundTrips('list of 100,000 ints', bigList, n: 500);
  await roundTrips('Uint8List of 1 MB', bytes, n: 500);
  print('  (TransferableTypedData of 1 MB can be sent once: '
      '${transferable.runtimeType})');

  print('\nOne-way sends to one isolate:');
  await oneWay('int', 7);
  await oneWay('small object (3 fields, list)', order);
  await oneWay('map of 50 entries', map, n: 50000);
  exit(0);
}
