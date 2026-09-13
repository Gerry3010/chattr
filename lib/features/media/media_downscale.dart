// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io' show Directory, File;

import 'package:easy_video_editor/easy_video_editor.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import '../../core/logging/logger_service.dart';
import '../settings/media_quality_controller.dart';
import 'editing/video_rotation_fix.dart';
import 'file_chunker.dart';
import 'image_metadata.dart';
import 'media_attachment.dart';
import 'media_cache_io.dart' show mediaCacheDirName;

/// Downscales photos and videos before sending — the voluntary saving option
/// ([MediaQuality]).
///
/// **Not to be confused with `media_compression.dart`.** That packs bytes into
/// gzip and deliberately leaves images, videos and audio alone, because there
/// is nothing left to gain there. Here things really are re-encoded: fewer
/// pixels, lower bitrate — so lossy, and therefore only on explicit request.
///
/// **The rule that holds it all together: never re-encode when it gains
/// nothing.** An image that is already small would only come out worse, and
/// "send smaller" would mean "send worse". So every branch first checks the
/// dimensions and in the end keeps the result only if it really is shorter than
/// the original.

/// Long edge an image is brought to at most.
const int kSmallerImageMaxEdge = 1600;

/// JPEG quality of the downscaled images. The same step as for the avatar —
/// visibly frugal, but not visibly broken.
const int kSmallerImageQuality = 85;

/// Target height for videos. 720p plays smoothly on every phone and is the step
/// at which the saving is most pronounced.
const VideoResolution kSmallerVideoResolution = VideoResolution.p720;

/// Whether video downscaling is possible on this platform.
///
/// `easy_video_editor` works natively and exists only for Android and iOS — the
/// same boundary as for trimming (`media_edit_launcher.dart`). On desktop and
/// in the browser videos stay unchanged; **images are downscaled anyway**, so
/// the switch is not without effect there, only less effective. A variable so
/// that tests can set it.
@visibleForTesting
bool Function() videoDownscaleSupported = () =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// Downscales [item] when [quality] demands it and it gains something.
///
/// Returns **[item] itself** when in doubt: for `original`, for unsupported
/// types, when the dimensions are already small enough, when the result would
/// not be smaller, and on any error. A failure here must never prevent sending
/// — better a large picture than none at all.
Future<OutgoingMedia> downscaleMedia(
  OutgoingMedia item,
  MediaQuality quality,
) async {
  if (quality == MediaQuality.original) return item;
  try {
    switch (MediaType.fromMime(item.mime)) {
      case MediaType.image:
        return await _downscaleImage(item);
      case MediaType.video:
        return await _downscaleVideo(item);
      case MediaType.audio:
      case MediaType.file:
        return item;
    }
  } catch (e) {
    logger.warning('Verkleinern übersprungen: $e', tag: 'MediaDownscale');
    return item;
  }
}

/// Applies [downscaleMedia] to a whole send. The order is preserved — it is the
/// order in the album.
Future<List<OutgoingMedia>> downscaleAll(
  List<OutgoingMedia> items,
  MediaQuality quality,
) async {
  if (quality == MediaQuality.original) return items;
  final out = <OutgoingMedia>[];
  for (final item in items) {
    out.add(await downscaleMedia(item, quality));
  }
  return out;
}

// ---------------------------------------------------------------------------
// Bild
// ---------------------------------------------------------------------------

Future<OutgoingMedia> _downscaleImage(OutgoingMedia item) async {
  // An animated GIF would lose its animation on re-encoding (package:image
  // gives us only the first frame). Better large and moving than small and
  // frozen — the same decision as for the avatar.
  if (item.mime.toLowerCase() == 'image/gif') return item;

  final source = item.bytes ?? await readFileBytes(item.sourcePath!);

  // **Order is not negotiable here.** `copyResize` does not evaluate the EXIF
  // orientation, and the freshly encoded result carries no EXIF any more.
  // Whoever downscales first has nothing left to bake in afterwards — and the
  // photo arrives tipped over at every recipient. So upright first (which also
  // strips GPS and the rest), then downscale.
  final upright = await ImageMetadata.normalizeAndStrip(source, item.mime);

  final resized = await compute(_resizeSync, (upright, item.mime));
  // Smaller than the ORIGINAL, not merely smaller than the uprighted
  // intermediate: otherwise a re-encode counts as a win as soon as merely the
  // uprighting cost space.
  if (resized == null || resized.length >= item.size) return item;

  final isPng = item.mime.toLowerCase() == 'image/png';
  return OutgoingMedia.bytes(
    resized,
    fileName: isPng
        ? item.fileName
        : '${_stripExtension(item.fileName)}.jpg',
    mime: isPng ? 'image/png' : 'image/jpeg',
  );
}

/// Runs in an isolate: decode, bound the long edge, re-encode. Returns `null`
/// when the image is already small enough or cannot be read — both mean "leave
/// unchanged" to the caller.
///
/// PNG stays PNG so transparency survives (a screenshot with a cut-out
/// background would otherwise get a black one); everything else becomes JPEG.
Uint8List? _resizeSync((Uint8List, String) input) {
  final (bytes, mime) = input;
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;

  final longest =
      decoded.width > decoded.height ? decoded.width : decoded.height;
  if (longest <= kSmallerImageMaxEdge) return null; // schon klein genug

  final resized = img.copyResize(
    decoded,
    width: decoded.width >= decoded.height ? kSmallerImageMaxEdge : null,
    height: decoded.height > decoded.width ? kSmallerImageMaxEdge : null,
    interpolation: img.Interpolation.average,
  );
  return mime.toLowerCase() == 'image/png'
      ? img.encodePng(resized)
      : img.encodeJpg(resized, quality: kSmallerImageQuality);
}

// ---------------------------------------------------------------------------
// Video
// ---------------------------------------------------------------------------

Future<OutgoingMedia> _downscaleVideo(OutgoingMedia item) async {
  if (!videoDownscaleSupported()) return item;

  // The native path works on files. A small video is present as bytes (below
  // the chunk threshold) — that is briefly spilled out and cleared away again
  // afterwards.
  String? spilled;
  final input = item.sourcePath ?? (spilled = await _spillToTemp(item));
  if (input == null) return item;

  try {
    final meta = await VideoEditorBuilder(videoPath: input).getVideoMetadata();
    // The SHORT edge decides: a portrait video is stored landscape in its raw
    // dimensions (1920×1080 with a rotation note), and "720p" means the short
    // side. Going by `height` alone would mean considering every portrait video
    // too small or treating every landscape one twice.
    final shortEdge = meta.width < meta.height ? meta.width : meta.height;
    if (shortEdge <= kSmallerVideoResolution.height) return item;

    final exported = await VideoEditorBuilder(videoPath: input)
        .compress(resolution: kSmallerVideoResolution)
        .export();
    if (exported == null) return item;

    // As with trimming: some native paths lose the rotation note on re-
    // encoding, and the video ends up on its side afterwards.
    final fixed =
        await restoreRotationIfDropped(meta, exported, tag: 'MediaDownscale');

    final size = await File(fixed).length();
    if (size >= item.size) {
      // Nothing gained — clear away the intermediate and stay with the
      // original. It really does happen with already frugally encoded clips.
      deleteVideoTempQuietly(fixed);
      return item;
    }
    logger.info(
      'Video verkleinert: ${item.size} → $size Bytes',
      tag: 'MediaDownscale',
    );
    return OutgoingMedia.file(
      fixed,
      size: size,
      fileName: item.fileName,
      mime: item.mime,
    );
  } finally {
    deleteVideoTempQuietly(spilled);
  }
}

/// Writes a memory-based video into a short-lived file so the native encoder
/// can work with it.
Future<String?> _spillToTemp(OutgoingMedia item) async {
  final bytes = item.bytes;
  if (bytes == null) return null;
  final dir = await getTemporaryDirectory();
  final cache = Directory('${dir.path}/$mediaCacheDirName');
  if (!cache.existsSync()) cache.createSync(recursive: true);
  final safe = item.fileName.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  final file = File(
      '${cache.path}/${DateTime.now().microsecondsSinceEpoch}_src_$safe');
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}

String _stripExtension(String fileName) {
  final dot = fileName.lastIndexOf('.');
  return dot > 0 ? fileName.substring(0, dot) : fileName;
}
