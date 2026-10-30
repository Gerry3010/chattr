// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:camera/camera.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/logging/logger_service.dart';
import '../../../core/navigation/app_page_route.dart';
import '../media_attachment.dart';
import 'chattr_camera_screen.dart';

/// What comes back from the camera.
class CameraCapture {
  /// Path of the captured file on the device.
  final String path;
  final String fileName;
  final String mime;

  /// Did the user capture in shot mode?
  final bool asShot;

  const CameraCapture({
    required this.path,
    required this.fileName,
    required this.mime,
    required this.asShot,
  });

  bool get isVideo => MediaType.fromMime(mime) == MediaType.video;
}

/// Does our own camera exist on this platform at all?
///
/// The same condition as on the tile before: on desktop and in the browser
/// there is no reliable capture path. `defaultTargetPlatform` instead of
/// `Platform.isAndroid` so it stays settable in a test.
bool get cameraCaptureSupported =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// Opens the Chattr camera and returns the capture — `null` when the user
/// cancelled.
///
/// **With a fallback.** If our own view cannot be opened (no device, plugin
/// error), the phone's camera app takes over as before. Capturing must not fail
/// just because our preview misbehaves on some device.
///
/// A **denied permission** is explicitly NOT a fallback case: the foreign app
/// fails on it just the same, and a second dialog right after would look as if
/// the refusal had not counted.
Future<CameraCapture?> openChattrCamera(
  BuildContext context, {
  bool initialShot = true,
}) async {
  List<CameraDescription> cameras = const [];
  try {
    cameras = await availableCameras();
  } on CameraException catch (e) {
    if (_isDenied(e)) rethrow;
    logger.warning('Kameraliste nicht lesbar (${e.code}) — Rückfall',
        tag: 'Camera');
  } catch (e) {
    logger.warning('Kameraliste nicht lesbar ($e) — Rückfall', tag: 'Camera');
  }

  if (cameras.isEmpty) {
    if (!context.mounted) return null;
    return _fallback(context, initialShot: initialShot);
  }

  if (!context.mounted) return null;
  return Navigator.of(context).push<CameraCapture>(
    appPageRoute<CameraCapture>(
      fullscreenDialog: true,
      builder: (_) =>
          ChattrCameraScreen(cameras: cameras, initialShot: initialShot),
    ),
  );
}

/// Was the camera denied by the user or by the system?
bool _isDenied(CameraException e) {
  final code = e.code.toLowerCase();
  return code.contains('denied') || code.contains('permission');
}

/// The route via the phone's camera app — exactly the one that existed before
/// our own view.
///
/// Because a foreign app does not know what we want, the question is asked
/// here: photo or video. That is the tap our own camera saves — here it is the
/// price for being able to capture anything at all.
Future<CameraCapture?> _fallback(
  BuildContext context, {
  required bool initialShot,
}) async {
  final video = await showModalBottomSheet<bool>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.photo_camera),
            title: Text('camera.photo'.tr()),
            onTap: () => Navigator.pop(ctx, false),
          ),
          ListTile(
            leading: const Icon(Icons.videocam),
            title: Text('camera.video'.tr()),
            onTap: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    ),
  );
  if (video == null) return null;

  final picker = ImagePicker();
  final XFile? capture = video
      ? await picker.pickVideo(source: ImageSource.camera)
      : await picker.pickImage(source: ImageSource.camera);
  if (capture == null) return null;

  return CameraCapture(
    path: capture.path,
    fileName: capture.name,
    mime: capture.mimeType ??
        mimeForExtension(capture.name.split('.').last),
    asShot: initialShot,
  );
}
