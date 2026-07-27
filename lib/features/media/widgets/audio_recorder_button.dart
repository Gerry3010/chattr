// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:cross_file/cross_file.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../../core/logging/logger_service.dart';
import '../media_attachment.dart' show OutgoingMedia;
import 'attach_menu.dart' show AttachSend;

/// Mic button that records a voice message and sends it as encrypted audio
/// media. Tap to start, tap again to stop & send.
class AudioRecorderButton extends StatefulWidget {
  final AttachSend onSend;
  final bool enabled;

  const AudioRecorderButton({
    super.key,
    required this.onSend,
    this.enabled = true,
  });

  @override
  State<AudioRecorderButton> createState() => _AudioRecorderButtonState();
}

class _AudioRecorderButtonState extends State<AudioRecorderButton> {
  final AudioRecorder _recorder = AudioRecorder();
  bool _recording = false;
  bool _busy = false;
  Duration _elapsed = Duration.zero;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_busy) return;
    if (_recording) {
      await _stopAndSend();
    } else {
      await _start();
    }
  }

  Future<void> _start() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      if (!await _recorder.hasPermission()) {
        messenger.showSnackBar(
          SnackBar(content: Text('media.mic_denied'.tr())),
        );
        return;
      }
      // Browsers' MediaRecorder does not support AAC-LC (the plugin default),
      // so recording on web threw "Encoder AudioEncoder.aacLc not supported".
      // Use Opus/WebM on web (widely supported), AAC-LC/m4a on native.
      final encoder = kIsWeb ? AudioEncoder.opus : AudioEncoder.aacLc;
      final ext = kIsWeb ? 'webm' : 'm4a';
      var path = '';
      if (!kIsWeb) {
        final dir = await getTemporaryDirectory();
        path = '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.$ext';
      }
      await _recorder.start(RecordConfig(encoder: encoder), path: path);
      logger.info('Voice recording started', tag: 'AudioRecorderButton');
      _elapsed = Duration.zero;
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _elapsed += const Duration(seconds: 1));
      });
      setState(() => _recording = true);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('media.record_error'.tr(args: ['$e']))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stopAndSend() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    _timer?.cancel();
    try {
      final out = await _recorder.stop();
      setState(() => _recording = false);
      if (out == null || out.isEmpty) return;
      final bytes = await XFile(out).readAsBytes();
      if (bytes.isEmpty) return;
      logger.info('Voice recording stopped (${bytes.length} bytes)',
          tag: 'AudioRecorderButton');
      await widget.onSend(
        items: [
          OutgoingMedia.bytes(
            bytes,
            fileName:
                'voice_${DateTime.now().millisecondsSinceEpoch}.${kIsWeb ? 'webm' : 'm4a'}',
            mime: kIsWeb ? 'audio/webm' : 'audio/mp4',
          ),
        ],
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('media.record_error'.tr(args: ['$e']))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _fmt(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.inMinutes)}:${two(d.inSeconds % 60)}';
  }

  @override
  Widget build(BuildContext context) {
    if (_recording) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_fmt(_elapsed),
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
          IconButton(
            icon: Icon(Icons.stop_circle,
                color: Theme.of(context).colorScheme.error),
            onPressed: _busy ? null : _toggle,
            tooltip: 'media.stop_recording'.tr(),
          ),
        ],
      );
    }
    return IconButton(
      icon: const Icon(Icons.mic),
      onPressed: widget.enabled && !_busy ? _toggle : null,
      tooltip: 'media.record'.tr(),
    );
  }
}
