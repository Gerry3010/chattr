// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

/// **Measurement entry point for accepting a call from the system UI — not
/// part of the app.**
///
/// Accepting a call on the Android lock screen opened a SECOND MainActivity
/// (with its own Flutter engine) in a task of its own: the plugin starts the
/// app from its TransparentActivity, which lives in a different task, and a
/// `singleTop` activity with an empty `taskAffinity` gets a fresh instance
/// there. The call ran on, invisible, in the first engine; the user looked at
/// a second app that knew nothing of it (2026-10-08).
///
/// The real path needs a push, and staging has no FCM. This entry point shows
/// the same system UI directly, so the launch can be measured without one:
///
/// ```bash
/// flutter build apk --release --target-platform android-arm64 \
///   -t lib/main_callkit_probe.dart --android-project-arg=chattrAppIdSuffix=.staging
/// adb install -r build/app/outputs/flutter-apk/app-release.apk
/// # tap "ring in 5 s", press Home, accept in the system UI, then:
/// adb shell dumpsys activity activities | grep -c 'Hist .*MainActivity'
/// ```
///
/// Each engine shows its own random tag; a tag that changes after accepting
/// is exactly the bug.
library;

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';

import 'features/calls/call_system_ui.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _Probe());
}

class _Probe extends StatefulWidget {
  const _Probe();

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  final _tag = Random().nextInt(1 << 20).toRadixString(16);
  final _events = <String>[];

  @override
  void initState() {
    super.initState();
    FlutterCallkitIncoming.onEvent.listen((e) {
      if (!mounted) return;
      setState(() => _events.add('${DateTime.now().second}s ${e.runtimeType}'));
    });
    FlutterCallkitIncoming.activeCalls().then((calls) {
      if (!mounted) return;
      setState(() => _events.add(
          'start: ${calls.map((c) => '${c.id}/${c.isAccepted}').join(', ')}'));
    });
  }

  Future<void> _ringSoon() async {
    await FlutterCallkitIncoming.requestNotificationPermission(<String, dynamic>{});
    await Future<void>.delayed(const Duration(seconds: 5));
    await FlutterCallkitIncoming.showCallkitIncoming(incomingCallParams(
      signalId: 'probe-${DateTime.now().millisecondsSinceEpoch}',
      chatId: 'probe-chat',
      callerName: 'Probe',
    ));
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('engine $_tag', style: const TextStyle(fontSize: 28)),
                const SizedBox(height: 12),
                FilledButton(
                  key: const ValueKey('ring'),
                  onPressed: _ringSoon,
                  child: const Text('ring in 5 s'),
                ),
                FilledButton(
                  onPressed: FlutterCallkitIncoming.endAllCalls,
                  child: const Text('end all'),
                ),
                const SizedBox(height: 12),
                for (final e in _events) Text(e),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
