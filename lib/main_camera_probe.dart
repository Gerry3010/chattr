// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

/// **Measurement entry point for the camera orientation — not part of the app.**
///
/// The rotation of the preview could not be derived: Android's
/// `Surface.ROTATION_*` and Flutter's `DeviceOrientation` name the same rotation in
/// opposite directions, and several plausible derivations gave opposite answers. So
/// it was measured on the device — only every measurement went through Gerry, and
/// three faults lay on top of each other.
///
/// This entry point closes the loop with no human in between: it opens the camera
/// view **directly**, without sign-in and without a chat. In the emulator the
/// virtual camera shows a test image with coloured edges (top red, right green,
/// bottom blue, left yellow) and a large "F" — with that a screenshot says
/// unambiguously which way up the preview is, and the "F" additionally reveals a
/// mirroring.
///
/// ```bash
/// emulator -avd <avd> -camera-back virtualscene \
///   -virtualscene-poster wall=<poster.png>
/// flutter run -d emulator-5556 -t lib/main_camera_probe.dart
/// adb -s emulator-5556 emu rotate      # change orientation
/// adb -s emulator-5556 exec-out screencap -p > shot.png
/// ```
library;

import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import 'features/media/camera/camera_launcher.dart';
import 'features/media/camera/chattr_camera_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await EasyLocalization.ensureInitialized();
  final cameras = await availableCameras();
  runApp(EasyLocalization(
    supportedLocales: const [Locale('de', 'DE'), Locale('en', 'US')],
    path: 'assets/translations',
    fallbackLocale: const Locale('de', 'DE'),
    child: _Probe(cameras: cameras),
  ));
}

class _Probe extends StatelessWidget {
  const _Probe({required this.cameras});

  final List<CameraDescription> cameras;

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        localizationsDelegates: context.localizationDelegates,
        supportedLocales: context.supportedLocales,
        locale: context.locale,
        theme: ThemeData.dark(),
        home: _Host(cameras: cameras),
      );
}

/// Shows **the captured file** after the shutter — in the same frame the
/// preview just stood in.
///
/// That is this rig's whole trick: the written file is demonstrably the right
/// way up (checked twice on the device). It is thereby the yardstick the
/// preview can be measured against — and the comparison no longer needs an eye
/// interpreting a corner of a room, only two screenshots side by side.
class _Host extends StatefulWidget {
  const _Host({required this.cameras});

  final List<CameraDescription> cameras;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  String? _shot;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_open()));
  }

  Future<void> _open() async {
    final result = await Navigator.of(context).push<CameraCapture>(
      MaterialPageRoute<CameraCapture>(
        builder: (_) => ChattrCameraScreen(cameras: widget.cameras),
      ),
    );
    if (result != null && mounted) setState(() => _shot = result.path);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        body: _shot == null
            ? const SizedBox.expand()
            : Stack(
                fit: StackFit.expand,
                children: [
                  Center(child: Image.file(File(_shot!))),
                  Positioned(
                    left: 12,
                    top: 40,
                    child: ColoredBox(
                      color: Colors.black87,
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: const Text('AUFGENOMMENE DATEI',
                            style: TextStyle(
                                color: Colors.greenAccent, fontSize: 16)),
                      ),
                    ),
                  ),
                ],
              ),
      );
}
