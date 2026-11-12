// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:mobile_probe/probe.dart';

/// The laptop end of the mobile probe: a probe node with a fixed identity,
/// so the phones can be built with its reference.
///
///     dart run bin/peer.dart [state file] [--check] [--label=x] [--seed=uri]
///
/// Prints its reference and writes it to `probe_uri.txt`; build the app
/// with `--dart-define=PROBE_SEED=$(cat probe_uri.txt)`. Every phone
/// reports what it sees here. With `--check`, the laptop also checks
/// every phone that joins. `--seed` makes it a second node that joins the
/// first, as a phone would (for trying the probe without phones). Stop
/// with Ctrl-C.
Future<void> main(List<String> args) async {
  final paths = args.where((a) => !a.startsWith('--'));
  String? option(String name) => [
    for (final a in args)
      if (a.startsWith('--$name=')) a.substring(name.length + 3),
  ].firstOrNull;
  final label = option('label') ?? 'laptop';
  final seed = option('seed');
  final stateFile = File(paths.isEmpty ? '.probe_state' : paths.first);
  if (!stateFile.existsSync()) {
    final random = Random.secure();
    stateFile.writeAsBytesSync(
      Uint8List.fromList([for (var i = 0; i < 64; i++) random.nextInt(256)]),
    );
  }
  final probe = await Probe.start(
    label: label,
    seedUri: seed,
    log: print,
    stateSeed: stateFile.readAsBytesSync(),
    autoCheck: args.contains('--check'),
  );
  if (seed == null) File('probe_uri.txt').writeAsStringSync(probe.uri);
  print(
    'reference${seed == null ? ' (also in probe_uri.txt)' : ''}:\n'
    '${probe.uri}',
  );
  await ProcessSignal.sigint.watch().first;
  await probe.close();
}
