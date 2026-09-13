// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io' show File, Platform;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../../core/navigation/app_page_route.dart';
import '../media_attachment.dart';
import 'image_editor_screen.dart';
import 'video_trim_screen.dart';

/// Which pre-send editor (if any) applies to a media item.
enum MediaEditKind { image, video, none }

/// Pure routing: which editor applies to [mime] on this platform. Kept free of
/// `Platform`/native calls so it is unit-testable — the widget layer supplies
/// [isMobile] via [_isMobile].
///
/// Images edit everywhere (`pro_image_editor` is pure-Flutter). Video trimming
/// is a native (Android/iOS) operation → mobile only; on desktop/web the video
/// is sent unedited. Audio and generic files have no editor.
MediaEditKind mediaEditKind(String mime, {required bool isMobile}) {
  switch (MediaType.fromMime(mime)) {
    case MediaType.image:
      return MediaEditKind.image;
    case MediaType.video:
      return isMobile ? MediaEditKind.video : MediaEditKind.none;
    case MediaType.audio:
    case MediaType.file:
      return MediaEditKind.none;
  }
}

/// True only on Android/iOS (native video trim available). `dart:io` Platform is
/// guarded by [kIsWeb] first — mirrors the camera-tile gate in attach_menu.dart.
bool get _isMobile => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

/// Whether [item] can be edited before sending on the current platform.
bool canEdit(OutgoingMedia item) {
  switch (mediaEditKind(item.mime, isMobile: _isMobile)) {
    case MediaEditKind.none:
      return false;
    // The image editor needs the decoded bytes (images always carry them).
    case MediaEditKind.image:
      return item.bytes != null;
    // Video trim is file-path based: works from either an in-memory source
    // (spilled to a temp file) or a large file-PATH source (chunked send).
    case MediaEditKind.video:
      return item.bytes != null || item.sourcePath != null;
  }
}

/// Result of [editMedia]: the edited media, plus (video only) the [trim]
/// settings that produced it so the caller can reopen the trimmer with them.
class EditResult {
  final OutgoingMedia item;
  final TrimSettings? trim;
  const EditResult(this.item, {this.trim});
}

/// Opens the appropriate editor for [item] and returns the edited media, or
/// `null` if the user backed out or the item is not editable here (caller keeps
/// the original). [initialTrim] restores a previous cut in the video editor.
/// Only the bytes/file (and, for images, the JPEG mime/extension) change — the
/// downstream encrypt/upload path is unchanged.
Future<EditResult?> editMedia(
  BuildContext context,
  OutgoingMedia item, {
  TrimSettings? initialTrim,
}) async {
  switch (mediaEditKind(item.mime, isMobile: _isMobile)) {
    case MediaEditKind.image:
      final edited = await Navigator.of(context).push<Uint8List>(
        appPageRoute<Uint8List>(
          fullscreenDialog: true,
          builder: (_) => ImageEditorScreen(bytes: item.bytes!),
        ),
      );
      if (edited == null) return null;
      // pro_image_editor always exports JPEG → reflect that in mime + name so
      // rendering and the compression-skip heuristic stay correct.
      return EditResult(OutgoingMedia.bytes(
        edited,
        fileName: '${_stripExtension(item.fileName)}.jpg',
        mime: 'image/jpeg',
      ));
    case MediaEditKind.video:
      // The trimmer returns the trimmed output file's PATH (large videos stay
      // out of RAM + chunk-capable) + the cut settings. Re-send as a file
      // source sized from disk; hand the settings back so the caller can reopen.
      final res = await Navigator.of(context).push<TrimResult>(
        appPageRoute<TrimResult>(
          fullscreenDialog: true,
          builder: (_) => VideoTrimScreen(
            bytes: item.bytes,
            sourcePath: item.sourcePath,
            fileName: item.fileName,
            initial: initialTrim,
          ),
        ),
      );
      if (res == null) return null;
      final size = await File(res.path).length();
      // Trim keeps the container format → same name/mime, new file.
      return EditResult(
        OutgoingMedia.file(res.path,
            size: size, fileName: item.fileName, mime: item.mime),
        trim: res.settings,
      );
    case MediaEditKind.none:
      return null;
  }
}

String _stripExtension(String fileName) {
  final dot = fileName.lastIndexOf('.');
  return dot > 0 ? fileName.substring(0, dot) : fileName;
}
