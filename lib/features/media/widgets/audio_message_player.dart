// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../media_attachment.dart';
import 'media_action_button.dart';
import 'media_message_view.dart' show decryptedMediaProvider;

/// Inline player for an encrypted audio / voice message. Decrypts the bytes on
/// demand (via [decryptedMediaProvider]) and plays them directly with
/// audioplayers' BytesSource — no temp file, no plaintext on disk.
class AudioMessagePlayer extends ConsumerStatefulWidget {
  final MediaAttachment attachment;
  const AudioMessagePlayer({super.key, required this.attachment});

  @override
  ConsumerState<AudioMessagePlayer> createState() =>
      _AudioMessagePlayerState();
}

class _AudioMessagePlayerState extends ConsumerState<AudioMessagePlayer> {
  final AudioPlayer _player = AudioPlayer();
  final List<StreamSubscription<dynamic>> _subs = [];
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  bool _loaded = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Keep the decoded source after playback ends — the default
    // ReleaseMode.release frees it, leaving play/seek dead until the widget is
    // recreated (the "can't replay until I leave & re-enter the chat" bug).
    _player.setReleaseMode(ReleaseMode.stop);
    _subs.add(_player.onPositionChanged.listen((p) {
      if (mounted) setState(() => _position = p);
    }));
    _subs.add(_player.onDurationChanged.listen((d) {
      if (mounted) setState(() => _duration = d);
    }));
    _subs.add(_player.onPlayerStateChanged.listen((s) {
      if (mounted) setState(() => _playing = s == PlayerState.playing);
    }));
    _subs.add(_player.onPlayerComplete.listen((_) async {
      // Rewind to the start so the next tap replays from 0 — on completion the
      // player sits at the end, so without this resume() is a no-op.
      await _player.seek(Duration.zero);
      if (mounted) {
        setState(() {
          _playing = false;
          _position = Duration.zero;
        });
      }
    }));
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle(Uint8List bytes) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (!_loaded) {
        await _player.setSource(
          BytesSource(bytes, mimeType: widget.attachment.mime),
        );
        _loaded = true;
      }
      if (_playing) {
        await _player.pause();
      } else {
        await _player.resume();
      }
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
    final async = ref.watch(decryptedMediaProvider(widget.attachment));
    return Container(
      width: 240,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: async.when(
        loading: () => const SizedBox(
          height: 40,
          child: Center(
            child: SizedBox(
              height: 18,
              width: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
        error: (_, _) => SizedBox(
          height: 40,
          child: Center(child: Text('media.load_error'.tr())),
        ),
        data: (bytes) {
          final total = _duration.inMilliseconds == 0
              ? 1.0
              : _duration.inMilliseconds.toDouble();
          final value =
              _position.inMilliseconds.clamp(0, total.toInt()).toDouble();
          return Row(
            children: [
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: Icon(_playing ? Icons.pause_circle : Icons.play_circle,
                    size: 32),
                color: Theme.of(context).colorScheme.primary,
                onPressed: () => _toggle(bytes),
              ),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SliderTheme(
                      data: const SliderThemeData(
                        trackHeight: 3,
                        thumbShape:
                            RoundSliderThumbShape(enabledThumbRadius: 6),
                      ),
                      child: Slider(
                        value: value,
                        max: total,
                        onChanged: (v) =>
                            _player.seek(Duration(milliseconds: v.toInt())),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(_fmt(_position),
                              style: Theme.of(context).textTheme.bodySmall),
                          Text(_fmt(_duration),
                              style: Theme.of(context).textTheme.bodySmall),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              MediaActionButton(attachment: widget.attachment, bytes: bytes),
            ],
          );
        },
      ),
    );
  }
}
