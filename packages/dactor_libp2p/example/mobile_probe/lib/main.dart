import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'probe.dart';

/// The laptop's reference, from `bin/peer.dart`:
/// `--dart-define=PROBE_SEED=$(cat probe_uri.txt)`.
const seedUri = String.fromEnvironment('PROBE_SEED');

void main() => runApp(const ProbeApp());

class ProbeApp extends StatelessWidget {
  const ProbeApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'dactor probe',
    theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
    home: const ProbeScreen(),
  );
}

class ProbeScreen extends StatefulWidget {
  const ProbeScreen({super.key});

  @override
  State<ProbeScreen> createState() => _ProbeScreenState();
}

class _ProbeScreenState extends State<ProbeScreen> with WidgetsBindingObserver {
  final _lines = <String>[];
  Probe? _probe;
  String _status = 'starting';
  DateTime? _pausedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_start());
  }

  void _show(String line) {
    // ignore: avoid_print
    print('PROBE $line');
    if (!mounted) return;
    setState(() {
      _lines.add(line);
      if (_lines.length > 500) _lines.removeAt(0);
    });
  }

  Future<void> _start() async {
    try {
      final probe = await Probe.start(
        label: Platform.operatingSystem,
        log: _show,
        seedUri: seedUri,
      );
      setState(() {
        _probe = probe;
        _status = seedUri.isEmpty ? 'running, no seed' : 'running';
      });
    } catch (e) {
      _show('start failed: $e');
      setState(() => _status = 'failed');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final probe = _probe;
    switch (state) {
      case AppLifecycleState.paused:
        _pausedAt = DateTime.now();
        probe?.log('app paused');
      case AppLifecycleState.resumed:
        final away = _pausedAt == null
            ? ''
            : ' after ${DateTime.now().difference(_pausedAt!).inSeconds} s';
        _pausedAt = null;
        probe?.log('app resumed$away');
        // What still works after being in the background.
        if (probe != null) {
          Timer(const Duration(seconds: 2), () => probe.checkAll());
        }
      default:
        break;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_probe?.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final probe = _probe;
    return Scaffold(
      appBar: AppBar(
        title: Text('dactor probe: ${Platform.operatingSystem}'),
        actions: [
          IconButton(
            tooltip: 'Copy my reference',
            icon: const Icon(Icons.copy),
            onPressed: probe == null
                ? null
                : () => Clipboard.setData(ClipboardData(text: probe.uri)),
          ),
          IconButton(
            tooltip: 'Check every member again',
            icon: const Icon(Icons.play_arrow),
            onPressed: probe == null ? null : () => probe.checkAll(),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                probe == null
                    ? _status
                    : '$_status · ${short(probe.node.id)} · '
                          '${probe.groups.members('probe').length} members',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                reverse: true,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: _lines.length,
                itemBuilder: (context, i) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    _lines[_lines.length - 1 - i],
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
