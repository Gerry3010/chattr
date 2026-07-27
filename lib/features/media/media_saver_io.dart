// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';

/// Whether saving a media file goes through the OS share sheet (mobile) rather
/// than a download / save-to-disk. Used by the UI to pick the right icon and
/// tooltip (share vs. download).
bool get mediaUsesShareSheet => Platform.isAndroid || Platform.isIOS;

/// Mobile: hand the file to the OS share sheet. Desktop (Linux/Windows/macOS):
/// the share sheet is unreliable/absent there, so save the file to a
/// user-chosen location via a native Save dialog instead.
Future<void> saveOrShareMedia({
  required String fileName,
  required String mimeType,
  required Uint8List bytes,
}) async {
  if (mediaUsesShareSheet) {
    await SharePlus.instance.share(ShareParams(
      files: [XFile.fromData(bytes, name: fileName, mimeType: mimeType)],
    ));
    return;
  }
  // Desktop: file_picker's saveFile shows the native Save dialog and returns
  // the chosen path, but on desktop it does NOT write the bytes there — we
  // write them ourselves. Returns null if the user cancels.
  final path = await FilePicker.saveFile(
    dialogTitle: 'Save media',
    fileName: fileName,
  );
  if (path != null) {
    await File(path).writeAsBytes(bytes);
  }
}

/// Save/share media that already exists as a file at [sourcePath] (a streamed
/// decrypt-to-temp-file, chunked media) — no need to load it into RAM. Mobile:
/// share the file directly; desktop: copy it to a user-chosen location.
Future<void> saveOrShareMediaPath({
  required String sourcePath,
  required String fileName,
  required String mimeType,
}) async {
  if (mediaUsesShareSheet) {
    await SharePlus.instance.share(ShareParams(
      files: [XFile(sourcePath, name: fileName, mimeType: mimeType)],
    ));
    return;
  }
  final dest = await FilePicker.saveFile(
    dialogTitle: 'Save media',
    fileName: fileName,
  );
  if (dest != null) {
    await File(sourcePath).copy(dest);
  }
}
