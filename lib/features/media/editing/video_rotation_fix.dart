// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:easy_video_editor/easy_video_editor.dart';

import '../../../core/logging/logger_service.dart';

/// Repairs a native video export result that has lost the original's rotation.
///
/// **The problem.** A portrait video stores the pixels in landscape and notes
/// beside them "rotate by 90° on playback". Some native export paths (above all
/// iOS' `AVAssetExportSession`) write the pixels out unchanged and **omit the
/// note** — the result then lies on its side for every viewer. Other paths
/// (Android/Media3) pass the note through, still others bake the rotation into
/// the pixels. All three are legitimate; only the first is broken.
///
/// **The detection.** The note counts as lost when the original had one, the
/// result has none — **and** the result has not become portrait. The second
/// condition separates "note gone" from "rotation baked in": if it was baked
/// in, the aspect ratio flips (landscape → portrait), and then everything is in
/// order. From the dimensions alone this **cannot** be decided once a step
/// additionally scales — which is why this version compares the orientation and
/// not the pixel count.
///
/// A pure precaution: on any error [outPath] comes back unchanged — at worst as
/// crooked as before, never more so.
///
/// A NOTE on direction: it is assumed that `rotate(degree:)` turns clockwise,
/// in line with the mp4/AVAsset convention. Android passes the note through, so
/// the branch does not run there at all; on iOS it does — should a portrait
/// video come out upside down, 90↔270 is the only inversion needed.
Future<String> restoreRotationIfDropped(
  VideoMetadata src,
  String outPath, {
  String tag = 'VideoExport',
}) async {
  final srcRot = src.rotation % 360;
  if (srcRot == 0) return outPath; // nichts zu bewahren
  try {
    final out = await VideoEditorBuilder(videoPath: outPath).getVideoMetadata();
    if (out.rotation % 360 != 0) return outPath; // Vermerk erhalten
    final srcLandscape = src.width > src.height;
    final outLandscape = out.width > out.height;
    if (srcLandscape != outLandscape) {
      // Die Drehung wurde in die Bildpunkte gebacken — richtig so.
      return outPath;
    }
    final degree = _rotationDegreeFor(srcRot);
    if (degree == null) return outPath; // unerwarteter Winkel → unangetastet
    logger.info('Export verlor die Drehung ($srcRot°) — wird neu gebacken',
        tag: tag);
    final rotated =
        await VideoEditorBuilder(videoPath: outPath).rotate(degree: degree).export();
    if (rotated == null || rotated == outPath) return outPath;
    deleteVideoTempQuietly(outPath); // die schiefe Zwischenstufe fällt weg
    return rotated;
  } catch (e) {
    logger.warning('Drehung-Reparatur übersprungen: $e', tag: tag);
    return outPath;
  }
}

RotationDegree? _rotationDegreeFor(int deg) {
  switch (deg) {
    case 90:
      return RotationDegree.degree90;
    case 180:
      return RotationDegree.degree180;
    case 270:
      return RotationDegree.degree270;
  }
  return null;
}

/// Deletes an intermediate file without a failure holding up the flow.
void deleteVideoTempQuietly(String? path) {
  if (path == null) return;
  try {
    final f = File(path);
    if (f.existsSync()) f.deleteSync();
  } catch (_) {
    // Best effort — a leftover temp file is no reason to stop.
  }
}
