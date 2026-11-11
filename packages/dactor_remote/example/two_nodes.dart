// Two operating-system processes talking through dactor_remote.
//
//   dart run example/two_nodes.dart server
//       prints an address, then serves until a client says goodbye
//   dart run example/two_nodes.dart client '<address>'
//
// The transport here is plain TCP, which is fine on one machine and wrong
// anywhere else: it has no authentication and no encryption.
import 'dart:async';
import 'dart:io';

import 'package:dactor/dactor.dart';
import 'package:dactor_remote/dactor_remote.dart';
import 'package:dactor_remote/tcp.dart';

sealed class KvMsg {}

final class Put extends KvMsg {
  final String key;
  final String value;
  Put(this.key, this.value);
}

final class Fetch extends KvMsg with Call<String?> {
  final String key;
  Fetch(this.key);
}

final class Goodbye extends KvMsg {}

/// Both processes register the same codecs.
CodecRegistry codecs() => CodecRegistry()
  ..register<Put>('Put',
      encode: (m, _) => [m.key, m.value],
      decode: (d, _) {
        final [key as String, value as String] = d as List;
        return Put(key, value);
      })
  ..register<Fetch>('Fetch',
      encode: (m, _) => m.key, decode: (d, _) => Fetch(d as String))
  ..register<Goodbye>('Goodbye',
      encode: (m, _) => null, decode: (d, _) => Goodbye());

class KeyValueStore extends GenServer<Map<String, String>, KvMsg> {
  final void Function() onGoodbye;
  KeyValueStore(this.onGoodbye);

  @override
  Map<String, String> init() => {};

  @override
  Map<String, String> handleCast(KvMsg message, Map<String, String> state) {
    switch (message) {
      case Put(:final key, :final value):
        print('[server] put $key = $value');
        return {...state, key: value};
      case Goodbye():
        onGoodbye();
        return state;
      case Fetch():
        return state;
    }
  }

  @override
  CallResult<Map<String, String>> handleCall(
          KvMsg request, Map<String, String> state, From from) =>
      switch (request) {
        Fetch(:final key) => request.reply(state[key], state),
        _ => NoReply(state),
      };
}

Future<void> server() async {
  final system = LocalActorSystem();
  final node = RemoteNode(system, await TcpTransport.bind(), codecs: codecs());
  final done = Completer<void>();
  final store = await system.spawn('store', () => KeyValueStore(done.complete));

  // The address carries the capability to use the store. Whoever has this
  // line can talk to it; nobody else can.
  print(node.uriOf(store));
  await done.future;
  await node.close();
  await system.shutdown();
}

Future<void> client(String address) async {
  final system = LocalActorSystem();
  final node = RemoteNode(system, await TcpTransport.bind(), codecs: codecs());
  final store = node.resolve(address).typed<KvMsg>();

  store.tell(Put('language', 'Dart'));
  store.tell(Put('model', 'actors'));
  print('[client] language = ${await store.call(Fetch('language'))}');
  print('[client] missing  = ${await store.call(Fetch('missing'))}');
  store.tell(Goodbye());

  // Give the goodbye time to leave before the socket closes.
  await Future<void>.delayed(const Duration(milliseconds: 100));
  await node.close();
  await system.shutdown();
}

Future<void> main(List<String> args) async {
  switch (args) {
    case ['server']:
      await server();
    case ['client', final address]:
      await client(address);
    default:
      stderr.writeln('usage: two_nodes.dart server | client <address>');
      exitCode = 64;
  }
}
