// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:easy_localization/easy_localization.dart';
import 'package:easy_video_editor/easy_video_editor.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/logging/logger_service.dart';
import '../video_render_config.dart';

/// The cut a user set in the trim screen — start/end (ms) + whether audio was
/// stripped. Remembered by the caller so re-opening the editor restores the
/// handles (and always re-trims from the ORIGINAL, never a prior trim).
class TrimSettings {
  final int startMs;
  final int endMs;
  final bool removeAudio;
  const TrimSettings({
    required this.startMs,
    required this.endMs,
    required this.removeAudio,
  });
}

/// What the trim screen returns: the trimmed output file [path] plus the
/// [settings] that produced it (so the caller can reopen with them).
class TrimResult {
  final String path;
  final TrimSettings settings;
  const TrimResult(this.path, this.settings);
}

/// Pre-send video editor (Android/iOS only): pick a start/end cut on a
/// scrubbable timeline and optionally strip the audio track. Native, no ffmpeg.
///
/// The preview + scrubbing run on media_kit (the app's playback engine — the
/// `video_trimmer` filmstrip failed to render on-device, so we roll our own
/// reliable RangeSlider trim bar with live preview seeking). The actual cut
/// (+ optional mute) is exported through `easy_video_editor` — the same native
/// engine that reliably strips audio on-device.
///
/// A small video arrives as [bytes] (spilled to a temp input file); a large one
/// arrives as a [sourcePath] and is used straight from disk (never in RAM — the
/// chunked-send source). Pops with the trimmed output file's **path** on
/// confirm, or `null` on back-out (caller keeps the original). Returning a path
/// (not bytes) keeps a large trimmed video chunk-capable on the send side.
class VideoTrimScreen extends StatefulWidget {
  final Uint8List? bytes;
  final String? sourcePath;
  final String fileName;

  /// Restores a previous cut (handles + audio) when the editor is reopened
  /// after the "too large" prompt was cancelled.
  final TrimSettings? initial;

  const VideoTrimScreen({
    super.key,
    this.bytes,
    this.sourcePath,
    required this.fileName,
    this.initial,
  }) : assert(bytes != null || sourcePath != null,
            'VideoTrimScreen needs either bytes or a sourcePath');

  @override
  State<VideoTrimScreen> createState() => _VideoTrimScreenState();
}

class _VideoTrimScreenState extends State<VideoTrimScreen> {
  Player? _player;
  VideoController? _controller;
  StreamSubscription<Duration>? _durSub;

  /// A temp input file we spilled from [bytes] and must delete on dispose. Null
  /// when trimming a caller-owned [sourcePath] directly (never delete that).
  File? _tempInput;

  /// The file path easy_video_editor trims (temp spill or the caller's path).
  String? _inputPath;

  bool _loaded = false;
  bool _saving = false;
  bool _removeAudio = false;
  bool _appliedInitial = false;

  double _durationMs = 0;
  double _startMs = 0;
  double _endMs = 0;

  @override
  void initState() {
    super.initState();
    _removeAudio = widget.initial?.removeAudio ?? false;
    _load();
  }

  Future<void> _load() async {
    try {
      final String input;
      if (widget.sourcePath != null) {
        input = widget.sourcePath!;
      } else {
        final tmp = await getTemporaryDirectory();
        final safeName = widget.fileName.replaceAll(RegExp(r'[^\w.\-]'), '_');
        final f = File('${tmp.path}/trim_input_$safeName');
        await f.writeAsBytes(widget.bytes!, flush: true);
        _tempInput = f;
        input = f.path;
      }
      _inputPath = input;

      final player = Player();
      final controller = VideoController(
        player,
        configuration: VideoControllerConfiguration(
          enableHardwareAcceleration: !useSoftwareVideoRendering,
        ),
      );
      // Duration arrives asynchronously once the demuxer reads the header — set
      // the trim range's end to the full length when it does.
      _durSub = player.stream.duration.listen((d) {
        if (d > Duration.zero && mounted) {
          setState(() {
            _durationMs = d.inMilliseconds.toDouble();
            // Restore a remembered cut once, else default end = full length.
            if (!_appliedInitial) {
              _appliedInitial = true;
              final init = widget.initial;
              if (init != null) {
                _startMs = init.startMs.toDouble().clamp(0.0, _durationMs);
                _endMs = init.endMs.toDouble().clamp(0.0, _durationMs);
                if (_endMs <= _startMs) _endMs = _durationMs;
              } else {
                _endMs = _durationMs;
              }
              _seek(_startMs);
            } else if (_endMs <= 0 || _endMs > _durationMs) {
              _endMs = _durationMs;
            }
          });
        }
      });
      await player.open(Media(input), play: false);
      if (!mounted) {
        await player.dispose();
        return;
      }
      setState(() {
        _player = player;
        _controller = controller;
        _loaded = true;
      });
    } catch (e) {
      logger.warning('Video trim load failed: $e', tag: 'VideoTrim');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('media.edit_failed'.tr(args: ['$e']))),
        );
        Navigator.of(context).pop(); // null → keep original
      }
    }
  }

  @override
  void dispose() {
    _durSub?.cancel();
    _player?.dispose();
    _deleteQuietly(_tempInput?.path);
    super.dispose();
  }

  Future<void> _seek(double ms) async {
    await _player?.seek(Duration(milliseconds: ms.round()));
  }

  Future<void> _save() async {
    if (_saving || !_loaded) return;
    setState(() => _saving = true);
    try {
      // Read the source rotation BEFORE trimming so we can restore it if the
      // native export drops it (see _restoreRotationIfDropped).
      final srcMeta =
          await VideoEditorBuilder(videoPath: _inputPath!).getVideoMetadata();

      var builder = VideoEditorBuilder(videoPath: _inputPath!)
          .trim(startTimeMs: _startMs.round(), endTimeMs: _endMs.round());
      if (_removeAudio) builder = builder.removeAudio();
      final trimmed = await builder.export();
      if (trimmed == null) throw StateError('export produced no file');

      // Some native trim paths (notably iOS AVAssetExportSession, but guarded
      // generically) re-encode without carrying the source's rotation flag, so
      // a portrait clip comes out sideways. Re-bake the lost rotation.
      final outPath = await _restoreRotationIfDropped(srcMeta, trimmed);
      // Pop the trimmed output's PATH + the settings used — the caller
      // reads/streams the file to send (keeps a large trimmed video
      // chunk-capable) and remembers the settings to reopen with. easy_video_
      // editor owns the temp; we keep the final file alive for the caller.
      if (mounted) {
        Navigator.of(context).pop(TrimResult(
          outPath,
          TrimSettings(
            startMs: _startMs.round(),
            endMs: _endMs.round(),
            removeAudio: _removeAudio,
          ),
        ));
      }
    } catch (e) {
      logger.warning('Video trim/export failed: $e', tag: 'VideoTrim');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('media.edit_failed'.tr(args: ['$e']))),
        );
        setState(() => _saving = false);
      }
    }
  }

  /// Corrects [trimmedPath] when the native trim dropped the source's rotation
  /// flag, leaving the raw (un-rotated) pixels tagged as 0° → the player renders
  /// a portrait clip sideways. Re-bakes exactly the lost rotation and returns
  /// the corrected file's path (deleting the sideways intermediate).
  ///
  /// Fires ONLY when the output kept the source's raw pixel dimensions AND
  /// zeroed the rotation flag — i.e. the flag was truly dropped. It is a no-op
  /// when the platform preserves the flag (Android/Media3) or bakes the pixels
  /// upright (dimensions would then differ). Best-effort: any metadata/export
  /// failure returns the trimmed path unchanged, never worse than before.
  ///
  /// NOTE: the corrective rotation direction assumes the package's
  /// `.rotate(degree:)` is clockwise, matching the mp4/AVAsset rotation-metadata
  /// convention. Android preserves the flag so this branch is a no-op there;
  /// iOS is where it actually runs — Mac verifies direction on-device and, if a
  /// portrait clip comes out upside-down, 90↔270 is the only flip needed.
  Future<String> _restoreRotationIfDropped(
      VideoMetadata src, String trimmedPath) async {
    final srcRot = src.rotation % 360;
    if (srcRot == 0) return trimmedPath; // source had no rotation to preserve
    try {
      final out =
          await VideoEditorBuilder(videoPath: trimmedPath).getVideoMetadata();
      final flagDropped = out.rotation % 360 == 0;
      final dimsUnchanged = out.width == src.width && out.height == src.height;
      if (!flagDropped || !dimsUnchanged) {
        // Flag preserved, or pixels were baked upright — nothing to fix.
        return trimmedPath;
      }
      final degree = _rotationDegreeFor(srcRot);
      if (degree == null) return trimmedPath; // unexpected angle → leave as-is
      logger.info(
        'Trim dropped rotation ($srcRot°) — re-baking it',
        tag: 'VideoTrim',
      );
      final rotated = await VideoEditorBuilder(videoPath: trimmedPath)
          .rotate(degree: degree)
          .export();
      if (rotated == null || rotated == trimmedPath) return trimmedPath;
      _deleteQuietly(trimmedPath); // drop the sideways intermediate
      return rotated;
    } catch (e) {
      logger.warning('Rotation restore skipped: $e', tag: 'VideoTrim');
      return trimmedPath;
    }
  }

  static RotationDegree? _rotationDegreeFor(int deg) {
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

  void _deleteQuietly(String? path) {
    if (path == null) return;
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {/* best-effort temp cleanup */}
  }

  static String _fmt(double ms) {
    final total = (ms / 1000).round();
    final m = (total ~/ 60).toString().padLeft(2, '0');
    final s = (total % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        leading: const BackButton(),
        title:
            Text('media.trim_video'.tr(), style: const TextStyle(fontSize: 16)),
        actions: [
          TextButton(
            onPressed: (_loaded && !_saving) ? _save : null,
            child: Text(
              'media.editor_done'.tr(),
              style: TextStyle(
                color: (_loaded && !_saving) ? Colors.white : Colors.white38,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
      body: !_loaded || _controller == null
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              children: [
                Column(
                  children: [
                    Expanded(
                      child: Video(controller: _controller!, fit: BoxFit.contain),
                    ),
                    _trimBar(),
                    SafeArea(
                      top: false,
                      child: SwitchListTile(
                        value: _removeAudio,
                        onChanged: (v) => setState(() => _removeAudio = v),
                        title: Text('media.remove_audio'.tr(),
                            style: const TextStyle(color: Colors.white)),
                        secondary: Icon(
                          _removeAudio ? Icons.volume_off : Icons.volume_up,
                          color: Colors.white70,
                        ),
                      ),
                    ),
                  ],
                ),
                if (_saving)
                  const ColoredBox(
                    color: Colors.black54,
                    child: Center(child: CircularProgressIndicator()),
                  ),
              ],
            ),
    );
  }

  /// Custom scrub/trim bar: a RangeSlider selects the [start, end] cut over the
  /// full duration; dragging a handle seeks the preview to that frame so the cut
  /// point is visible. Labels show start · selected length · end.
  Widget _trimBar() {
    if (_durationMs <= 0) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: LinearProgressIndicator(),
      );
    }
    final start = _startMs.clamp(0.0, _durationMs);
    final end = _endMs.clamp(0.0, _durationMs);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          RangeSlider(
            min: 0,
            max: _durationMs,
            values: RangeValues(start, end <= start ? _durationMs : end),
            labels: RangeLabels(_fmt(start), _fmt(end)),
            activeColor: Theme.of(context).colorScheme.primary,
            inactiveColor: Colors.white24,
            onChanged: (v) {
              // Seek the preview to whichever handle the user is dragging.
              final startMoved = (v.start - _startMs).abs() >=
                  (v.end - _endMs).abs();
              setState(() {
                _startMs = v.start;
                _endMs = v.end;
              });
              _seek(startMoved ? v.start : v.end);
            },
          ),
          Row(
            children: [
              Text(_fmt(start),
                  style: const TextStyle(color: Colors.white70, fontSize: 12)),
              Expanded(
                child: Center(
                  child: Text(
                    'media.trim_selected'
                        .tr(args: [_fmt((end - start).clamp(0, _durationMs))]),
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ),
              ),
              Text(_fmt(end),
                  style: const TextStyle(color: Colors.white70, fontSize: 12)),
            ],
          ),
        ],
      ),
    );
  }
}
