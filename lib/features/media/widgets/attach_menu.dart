// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async' show StreamSubscription, unawaited;
import 'dart:io' show File, Platform;
import 'dart:typed_data';

import 'package:camera/camera.dart' show CameraException;
import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MissingPluginException, PlatformException;
import 'package:image_picker/image_picker.dart';

import '../../../core/logging/logger_service.dart';
import '../camera/camera_launcher.dart';
import '../clipboard_paste.dart';
import '../ios_media_channel.dart';
import '../media_attachment.dart';
import '../media_repository.dart';
import '../../settings/media_quality_controller.dart';
import 'media_caption_sheet.dart';
import 'send_progress_dialog.dart';
import '../../../core/network/network_errors.dart';

/// Callback that sends one or more picked files as a single encrypted media
/// album, with an optional shared text caption (#109/#110). [onProgress] (0..1)
/// reports upload progress so the caller can drive a determinate progress box
/// (large-video processing) — omitted for callers that don't need it.
typedef AttachSend = Future<void> Function({
  required List<OutgoingMedia> items,
  String? caption,
  void Function(double fraction)? onProgress,
  bool Function()? isCancelled,
  MediaQuality? quality,
  bool asShot,
});

/// Maximum media items per album send (#109). Keeps the in-RAM encrypt bounded
/// and the mosaic legible.
const int maxAlbumItems = 10;

/// Shared media-send path (attach picker, camera, clipboard): enforces the
/// per-file upload-size limit and album cap, warns before a large in-RAM
/// encrypt, shows the preview + shared caption ONCE, then hands the batch to
/// [onSend] (E2E-encrypt + send). Errors surface as a snackbar. [context] must
/// be mounted with a [ScaffoldMessenger] ancestor.
Future<void> sendMediaItems({
  required BuildContext context,
  required AttachSend onSend,
  required List<OutgoingMedia> items,
  String? initialText,
  bool initialAsShot = false,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  if (items.isEmpty) return;
  if (items.length > maxAlbumItems) {
    messenger.showSnackBar(
      SnackBar(content: Text('media.too_many'.tr(args: ['$maxAlbumItems']))),
    );
    return;
  }
  // Per-file hard cap (the server caps each object, not the sum).
  final tooLarge =
      items.any((i) => i.size > MediaRepository.maxUploadBytes);
  if (tooLarge) {
    messenger.showSnackBar(
      SnackBar(
        content:
            Text('media.too_large'.tr(args: [MediaRepository.maxUploadLabel])),
      ),
    );
    return;
  }
  // Preview + per-item edit + one shared caption for the whole batch
  // (#109/#110 + media-editing). Backing out aborts; an empty caption sends
  // without one. The sheet may return EDITED items (crop/draw, trim, mute).
  if (!context.mounted) return;
  // The sheet validates size itself (hard cap + large-send warning) so a "too
  // large" cancel keeps the user in the editor with their trim settings; it
  // only returns items that are cleared to send.
  final result = await showMediaCaptionSheet(context,
      items: items, initialText: initialText, initialAsShot: initialAsShot);
  if (result == null) return; // backed out, or cancelled the size prompt
  final edited = result.items;
  final caption = result.caption;
  // Big sends (esp. large videos) run a non-dismissible determinate progress
  // box so the user waits on the encrypt+upload instead of a frozen UI; tiny
  // images skip it (would only flash). Message is video-aware.
  final totalOut = edited.fold<int>(0, (s, i) => s + i.size);
  final hasVideo =
      edited.any((i) => MediaType.fromMime(i.mime) == MediaType.video);
  final showProgress = totalOut > 3 * 1024 * 1024;
  final progress = ValueNotifier<double>(0);
  var cancelled = false;
  var dialogOpen = false;
  void closeDialog() {
    if (dialogOpen && context.mounted) {
      dialogOpen = false;
      Navigator.of(context, rootNavigator: true).pop();
    }
  }

  if (showProgress && context.mounted) {
    dialogOpen = true;
    showSendProgressDialog(
      context,
      progress,
      isVideo: hasVideo,
      onCancel: () {
        cancelled = true; // aborts at the next chunk/file boundary
        closeDialog();
      },
    );
  }
  try {
    await onSend(
      items: edited,
      caption: caption.isEmpty ? null : caption,
      onProgress: showProgress ? (p) => progress.value = p : null,
      isCancelled: showProgress ? () => cancelled : null,
      // `null` = as configured; only an explicit choice in the sheet travels
      // along as an override.
      quality: result.quality,
      asShot: result.asShot,
    );
  } on MediaSendCancelledException {
    // User aborted the send via the progress box — no error to show.
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text(isNetworkError(e)
          ? 'errors.send_offline'.tr()
          : 'media.send_error'.tr(args: ['$e']))),
    );
  } finally {
    closeDialog();
    progress.dispose();
  }
}

/// Single-file convenience wrapper around [sendMediaItems] (camera, clipboard).
Future<void> sendMediaBytes({
  required BuildContext context,
  required AttachSend onSend,
  required Uint8List bytes,
  required String fileName,
  required String mime,
  String? initialText,
  bool initialAsShot = false,
}) =>
    sendMediaItems(
      context: context,
      onSend: onSend,
      items: [OutgoingMedia.bytes(bytes, fileName: fileName, mime: mime)],
      initialText: initialText,
      initialAsShot: initialAsShot,
    );

/// WhatsApp-style attach sheet: a grid of media sources. Each opens the picker
/// for its type and hands the bytes to [onSend] (which E2E-encrypts + sends).
Future<void> showAttachSheet({
  required BuildContext context,
  required AttachSend onSend,
  String? initialText,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        child: Wrap(
          alignment: WrapAlignment.center,
          spacing: 24,
          runSpacing: 20,
          children: [
            // Capturing exists only on the phone — see
            // [cameraCaptureSupported], which keeps the condition (and the
            // reason it hangs on `defaultTargetPlatform`) in one place.
            if (cameraCaptureSupported)
              _AttachOption(
                icon: Icons.timer,
                color: Colors.teal,
                // The tile is called "Shot" because it starts in shot mode —
                // that can be toggled in the camera itself and once more in the
                // send sheet afterwards.
                //
                // **No second gesture any more.** Short/long sat here because
                // capture belonged to a foreign app and this was the only
                // reachable place. Now both live where one looks for them: on
                // the shutter.
                label: 'shots.badge'.tr(),
                onTap: () => _captureAndSend(sheetContext, onSend, initialText),
              ),
            _AttachOption(
              icon: Icons.photo_library,
              color: Colors.purple,
              label: 'media.gallery'.tr(),
              onTap: () =>
                  _pickAndSend(sheetContext, FileType.image, onSend, initialText),
            ),
            _AttachOption(
              icon: Icons.videocam,
              color: Colors.red,
              label: 'media.video'.tr(),
              onTap: () =>
                  _pickAndSend(sheetContext, FileType.video, onSend, initialText),
            ),
            _AttachOption(
              icon: Icons.audiotrack,
              color: Colors.orange,
              label: 'media.audio'.tr(),
              onTap: () =>
                  _pickAndSend(sheetContext, FileType.audio, onSend, initialText),
            ),
            _AttachOption(
              icon: Icons.insert_drive_file,
              color: Colors.blue,
              label: 'media.document'.tr(),
              onTap: () =>
                  _pickAndSend(sheetContext, FileType.any, onSend, initialText),
            ),
            // Paste an image/file from the clipboard. Complements the desktop/
            // web Ctrl/Cmd+V shortcut and is the primary paste entry on mobile.
            _AttachOption(
              icon: Icons.content_paste,
              color: Colors.blueGrey,
              label: 'media.paste'.tr(),
              onTap: () => _pasteAndSend(sheetContext, onSend, initialText),
            ),
          ],
        ),
      ),
    ),
  );
}

Future<void> _pickAndSend(
  BuildContext sheetContext,
  FileType type,
  AttachSend onSend,
  String? initialText,
) async {
  final messenger = ScaffoldMessenger.of(sheetContext);
  final navigator = Navigator.of(sheetContext);
  final rootContext = navigator.context;
  navigator.pop();
  try {
    // iOS video: route through image_picker, NOT file_picker. On iOS file_picker
    // uses PHPicker's `loadFileRepresentation(forTypeIdentifier: public.movie)`,
    // which fails to materialize HEVC / iCloud "optimized storage" clips with
    // "Cannot load representation of type public.movie" — the by-path pick then
    // silently no-ops and leaves a pending request that makes the next attempt
    // throw `multiple_request`. image_picker uses AVAssetExportSession, which
    // writes a local copy that works for those clips and hands back a real path
    // we can chunk-upload. Images/documents and all other platforms keep
    // file_picker (Android by-path is verified working).
    if (!kIsWeb && Platform.isIOS && type == FileType.video) {
      await _pickIosVideoAndSend(rootContext, messenger, onSend, initialText);
      return;
    }
    // iOS audio: file_picker maps FileType.audio to MPMediaPickerController — the
    // Apple Music library. Nothing useful can be attached from there (wrong
    // place, and DRM tracks can't even be exported), so route to the document
    // picker filtered to audio files instead (Files / iCloud Drive, including
    // voice memos the user exported there). Recording a voice message is a
    // separate flow (the composer mic). Other platforms keep FileType.audio,
    // where the native audio picker works.
    var effectiveType = type;
    List<String>? allowedExtensions;
    if (!kIsWeb && Platform.isIOS && type == FileType.audio) {
      effectiveType = FileType.custom;
      allowedExtensions = const [
        'm4a', 'mp3', 'wav', 'aac', 'aiff', 'caf', 'flac', 'ogg', 'opus',
      ];
    }
    // Multi-select → one album (#109); the caption sheet appears once.
    // withData only on web (no file paths there). On native we read the bytes
    // ourselves from the path AFTER a size check, so an oversized file is
    // refused up-front instead of file_picker's eager withData allocation
    // OOM-crashing the app (the 113 MB video crash).
    final result = await FilePicker.pickFiles(
      type: effectiveType,
      allowedExtensions: allowedExtensions,
      withData: kIsWeb,
      allowMultiple: true,
    );
    final picked = result?.files ?? [];
    if (picked.isEmpty) return;
    logger.info('Attach: picked ${picked.length} file(s)', tag: 'AttachMenu');
    final items = await _filesToOutgoingMedia(picked, messenger);
    if (items.isEmpty) return;
    if (!rootContext.mounted) return;
    await sendMediaItems(
      context: rootContext,
      onSend: onSend,
      items: items,
      initialText: initialText,
    );
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text(isNetworkError(e)
          ? 'errors.send_offline'.tr()
          : 'media.send_error'.tr(args: ['$e']))),
    );
  }
}

/// Convert picked [PlatformFile]s into send-ready [OutgoingMedia], applying the
/// same size guards + chunk routing as the send path (large native videos keep
/// their path for chunked upload; oversized in-memory files are refused with a
/// snackbar and skipped). Shared by the attach flow and the caption sheet's "+".
Future<List<OutgoingMedia>> _filesToOutgoingMedia(
  List<PlatformFile> picked,
  ScaffoldMessengerState messenger,
) async {
  final items = <OutgoingMedia>[];
  for (final f in picked) {
    final mime = mimeForExtension(f.extension);
    // Any large path-backed file → CHUNKED: keep the PATH, stream it later,
    // never load the whole thing into RAM (fixes the large-media OOM — videos
    // AND big documents/archives alike). No path (web) → must go through bytes.
    if (!kIsWeb &&
        f.path != null &&
        f.size > MediaRepository.chunkThresholdBytes) {
      items.add(OutgoingMedia.file(f.path!,
          size: f.size, fileName: f.name, mime: mime));
      continue;
    }
    // Small files → in-memory bytes. The RAM ceiling only bites the web/pathless
    // case now: a large native file above already took the chunked path, so this
    // reject can only trigger when there's no path to stream from.
    if (f.size > MediaRepository.maxInMemoryBytes) {
      messenger.showSnackBar(SnackBar(
        content: Text(
            'media.too_large'.tr(args: [MediaRepository.maxInMemoryLabel])),
      ));
      continue;
    }
    final bytes = f.bytes ??
        (f.path != null ? await File(f.path!).readAsBytes() : null);
    if (bytes == null) continue;
    items.add(OutgoingMedia.bytes(bytes, fileName: f.name, mime: mime));
  }
  return items;
}

/// Pick MORE media (default: images) from the gallery/files WITHOUT sending —
/// used by the caption sheet's "+" to grow the batch into an album. Mirrors the
/// send path's size guards + chunk routing. Returns [] on cancel/none.
Future<List<OutgoingMedia>> pickMoreMedia(
  BuildContext context, {
  FileType type = FileType.image,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final result = await FilePicker.pickFiles(
    type: type,
    withData: kIsWeb,
    allowMultiple: true,
  );
  final picked = result?.files ?? [];
  if (picked.isEmpty) return const [];
  return _filesToOutgoingMedia(picked, messenger);
}

/// iOS gallery video pick. Prefers the native PhotoKit shim
/// ([IosMediaChannel.pickGalleryVideo]) which deterministically materializes
/// iCloud "Optimize Storage" clips; falls back to the `image_picker` interim
/// ([_pickIosVideoViaImagePicker]) when the native side isn't in the build yet
/// ([MissingPluginException]). Either way the resulting local path feeds the
/// existing chunk/bytes send routing.
Future<void> _pickIosVideoAndSend(
  BuildContext rootContext,
  ScaffoldMessengerState messenger,
  AttachSend onSend,
  String? initialText,
) async {
  final progress = ValueNotifier<double?>(null);
  StreamSubscription<double>? sub;
  var dialogShown = false;
  void closeDialog() {
    if (dialogShown && rootContext.mounted) {
      Navigator.of(rootContext, rootNavigator: true).pop();
    }
    dialogShown = false;
  }

  IosPickedVideo? picked;
  try {
    // Show the "downloading from iCloud" dialog only once a real download is in
    // flight (first sub-1.0 progress event) — a local clip materializes instantly
    // and shouldn't flash a dialog.
    sub = IosMediaChannel.progress.listen((p) {
      progress.value = p;
      if (p < 0.999 && !dialogShown && rootContext.mounted) {
        dialogShown = true;
        unawaited(showDialog<void>(
          context: rootContext,
          barrierDismissible: false,
          builder: (_) => PopScope(
            canPop: false,
            child: AlertDialog(
              content: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 16),
                  Flexible(
                    child: ValueListenableBuilder<double?>(
                      valueListenable: progress,
                      builder: (_, v, _) => Text(v == null
                          ? 'media.icloud_downloading_indeterminate'.tr()
                          : 'media.icloud_downloading'
                              .tr(args: ['${(v * 100).round()}'])),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ));
      }
    });
    picked =
        await IosMediaChannel.pickGalleryVideo(maxBytes: MediaRepository.maxUploadBytes);
  } on MissingPluginException {
    // Native shim not in this build → fall back to the image_picker interim.
    await sub?.cancel();
    closeDialog();
    if (!rootContext.mounted) return;
    await _pickIosVideoViaImagePicker(
        rootContext, messenger, onSend, initialText);
    return;
  } on PlatformException catch (e) {
    await sub?.cancel();
    closeDialog();
    logger.warning('Attach: native iOS video pick failed: ${e.code}',
        tag: 'AttachMenu');
    final msg = switch (e.code) {
      'too_large' =>
        'media.too_large'.tr(args: [MediaRepository.maxUploadLabel]),
      'no_permission' => 'media.no_photo_permission'.tr(),
      _ => 'media.icloud_not_ready'.tr(),
    };
    messenger.showSnackBar(SnackBar(content: Text(msg)));
    return;
  } finally {
    await sub?.cancel();
    closeDialog();
    progress.dispose();
  }
  if (picked == null) return; // user cancelled

  final path = picked.path;
  try {
    final mime = picked.mime ?? mimeForExtension(picked.name.split('.').last);
    final len = picked.size;
    logger.info('Attach: native iOS video ${picked.name} ($len bytes)',
        tag: 'AttachMenu');
    final items = <OutgoingMedia>[
      // Native side already enforced maxUploadBytes; >16 MiB streams as chunks
      // (the OOM fix), smaller goes through bytes.
      if (len > MediaRepository.chunkThresholdBytes)
        OutgoingMedia.file(path, size: len, fileName: picked.name, mime: mime)
      else
        OutgoingMedia.bytes(await File(path).readAsBytes(),
            fileName: picked.name, mime: mime),
    ];
    if (!rootContext.mounted) return;
    await sendMediaItems(
        context: rootContext,
        onSend: onSend,
        items: items,
        initialText: initialText);
  } finally {
    // The native temp file is ours to clean up once the send (or cancel) is done.
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}

/// iOS gallery video pick via `image_picker` — the interim fallback used until
/// the native PhotoKit shim ships in a build. Returns a real local path —
/// chunked when large (the OOM fix), else sent as bytes. Single-select:
/// `image_picker` doesn't do reliable multi-video on iOS, and this path exists
/// precisely because file_picker's multi-select fails there anyway.
Future<void> _pickIosVideoViaImagePicker(
  BuildContext rootContext,
  ScaffoldMessengerState messenger,
  AttachSend onSend,
  String? initialText,
) async {
  final XFile? video;
  try {
    video = await ImagePicker().pickVideo(source: ImageSource.gallery);
  } on PlatformException catch (e) {
    // Both image_picker and file_picker resolve the pick through PHPicker's
    // `NSItemProvider.loadFileRepresentation`, which throws when the clip isn't
    // materialized locally yet — iCloud "Optimize Storage" evicts it and only
    // downloads it on first access ("Cannot load representation of type
    // public.movie / public.mpeg-4", codes invalid_image / multiple_request).
    // It's transient: re-picking succeeds once iCloud has pulled the file down.
    // Surface a clear, actionable hint instead of a generic send error or a
    // silent no-op. (A deterministic download would need a photo_manager-based
    // PHAsset requestAVAsset(isNetworkAccessAllowed:true) path — bigger change.)
    final msg = '${e.message ?? ''} ${e.code}';
    if (msg.contains('Cannot load representation') ||
        e.code == 'invalid_image' ||
        e.code == 'multiple_request') {
      logger.warning('Attach: iOS video not materialized (iCloud?): ${e.code}',
          tag: 'AttachMenu');
      messenger.showSnackBar(
        SnackBar(content: Text('media.icloud_not_ready'.tr())),
      );
      return;
    }
    rethrow; // unrelated failure → outer handler shows the generic error
  }
  if (video == null) return; // user cancelled
  final len = await video.length();
  final mime = video.mimeType ?? mimeForExtension(video.name.split('.').last);
  logger.info('Attach: picked iOS video ${video.name} ($len bytes)',
      tag: 'AttachMenu');
  final items = <OutgoingMedia>[];
  // We KNOW this is a video, so gate chunking on size alone (no mime sniffing).
  if (video.path.isNotEmpty && len > MediaRepository.chunkThresholdBytes) {
    items.add(OutgoingMedia.file(video.path,
        size: len, fileName: video.name, mime: mime));
  } else {
    if (len > MediaRepository.maxInMemoryBytes) {
      messenger.showSnackBar(SnackBar(
        content:
            Text('media.too_large'.tr(args: [MediaRepository.maxInMemoryLabel])),
      ));
      return;
    }
    items.add(OutgoingMedia.bytes(await video.readAsBytes(),
        fileName: video.name, mime: mime));
  }
  if (!rootContext.mounted) return;
  await sendMediaItems(
      context: rootContext,
      onSend: onSend,
      items: items,
      initialText: initialText);
}

/// Clipboard tile: read an image/file from the clipboard and send it through
/// the shared [sendMediaBytes] pipeline (with preview + size checks). Shows a
/// hint when the clipboard holds no pasteable media.
Future<void> _pasteAndSend(
  BuildContext sheetContext,
  AttachSend onSend,
  String? initialText,
) async {
  final messenger = ScaffoldMessenger.of(sheetContext);
  final navigator = Navigator.of(sheetContext);
  final rootContext = navigator.context;
  navigator.pop();
  if (!rootContext.mounted) return;
  final handled = await pasteClipboardMedia(
      context: rootContext, onSend: onSend, initialText: initialText);
  if (!handled) {
    messenger.showSnackBar(
      SnackBar(content: Text('media.paste_empty'.tr())),
    );
  }
}

/// Shot tile: open our own camera and push the capture through the same
/// [AttachSend] chain as selected files.
///
/// Photo or video is now decided by the **shutter** in the camera, no longer by
/// the tile: tap = photo, hold = video, and in video mode one tap starts and
/// one ends it. Whether it becomes a shot arrives as a preset from the camera
/// and can still be flipped in the send sheet.
Future<void> _captureAndSend(
  BuildContext sheetContext,
  AttachSend onSend,
  String? initialText,
) async {
  final messenger = ScaffoldMessenger.of(sheetContext);
  final navigator = Navigator.of(sheetContext);
  final rootContext = navigator.context;

  navigator.pop(); // close the attach sheet before opening the camera

  try {
    final capture = await openChattrCamera(rootContext);
    if (capture == null) return; // abgebrochen

    final len = await File(capture.path).length();
    if (!rootContext.mounted) return;
    // A large capture (long video recording, or a high-res photo above the
    // threshold) is CHUNKED from its path — never loaded whole into RAM (same
    // OOM fix as the picker); smaller captures go through bytes.
    if (len > MediaRepository.chunkThresholdBytes) {
      logger.info('Attach: captured ${capture.fileName} ($len bytes, chunked)',
          tag: 'AttachMenu');
      await sendMediaItems(
        context: rootContext,
        onSend: onSend,
        items: [
          OutgoingMedia.file(capture.path,
              size: len, fileName: capture.fileName, mime: capture.mime),
        ],
        initialText: initialText,
        initialAsShot: capture.asShot,
      );
      return;
    }
    final bytes = await File(capture.path).readAsBytes();
    logger.info('Attach: captured ${capture.fileName} (${bytes.length} bytes)',
        tag: 'AttachMenu');
    if (!rootContext.mounted) return;
    await sendMediaBytes(
      context: rootContext,
      onSend: onSend,
      bytes: bytes,
      fileName: capture.fileName,
      mime: capture.mime,
      initialText: initialText,
      initialAsShot: capture.asShot,
    );
  } on CameraException catch (e) {
    // Denied permission: our own camera fails on it just as the foreign app did
    // before — hence the same message and NO fallback.
    logger.warning('Kamera verweigert/fehlgeschlagen: ${e.code}',
        tag: 'AttachMenu');
    messenger.showSnackBar(
      SnackBar(content: Text('media.camera_denied'.tr())),
    );
  } on PlatformException catch (e) {
    logger.warning('Aufnahme fehlgeschlagen: ${e.code}', tag: 'AttachMenu');
    messenger.showSnackBar(
      SnackBar(content: Text('media.camera_denied'.tr())),
    );
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text(isNetworkError(e)
          ? 'errors.send_offline'.tr()
          : 'media.send_error'.tr(args: ['$e']))),
    );
  }
}

class _AttachOption extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onTap;

  /// **No `onLongPress` and no hint any more.** The camera was the only tile
  /// with a second gesture — it had to go there because capture belonged to a
  /// foreign app. Now "tap/hold" sits on our own camera's shutter, and a tile
  /// does exactly one thing again. The field is deliberately removed rather
  /// than left unused: a hidden second behaviour otherwise creeps back in.
  const _AttachOption({
    required this.icon,
    required this.color,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 72,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 28,
              backgroundColor: color,
              child: Icon(icon, color: Colors.white, size: 26),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
