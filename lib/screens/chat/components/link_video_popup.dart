// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

import '../../../core/logging/logger_service.dart';
import '../../../features/media/pip_controller.dart';
import '../../../features/media/video_render_config.dart';
import '../../../features/messages/message_links.dart';

/// The YouTube iframe player rides on webview_flutter, which has no
/// Linux/Windows implementation — there the thumbnail keeps opening the
/// link externally like before.
bool get youtubePopupSupported =>
    kIsWeb ||
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS ||
    defaultTargetPlatform == TargetPlatform.macOS;

/// Whether tapping the preview thumbnail of [uri] can open an in-app player
/// on this platform. [videoUrl] is a directly playable stream (Reddit HLS /
/// og:video) resolved by the preview fetch, if any.
bool canPlayLinkInPopup(Uri uri, String? videoUrl) =>
    videoUrl != null || (youtubeVideoId(uri) != null && youtubePopupSupported);

/// Opens the in-app popup player for [uri]: YouTube links play through the
/// official iframe player, anything with a resolved [videoUrl] (Reddit HLS,
/// og:video) through a media_kit dialog. Falls back to launching the link
/// externally when neither applies on this platform.
Future<void> showLinkVideoPopup(
  BuildContext context,
  Uri uri, {
  String? videoUrl,
}) async {
  final ytId = youtubeVideoId(uri);
  if (ytId != null && youtubePopupSupported) {
    final shorts = isYoutubeShorts(uri);
    return showDialog<void>(
      context: context,
      builder: (_) => _VideoPopupDialog(
        vertical: shorts,
        child: _YoutubePopupPlayer(
          videoId: ytId,
          aspectRatio: shorts ? 9 / 16 : 16 / 9,
        ),
      ),
    );
  }
  if (videoUrl != null) {
    return showDialog<void>(
      context: context,
      builder: (_) => _VideoPopupDialog(
        // Reddit videos are commonly vertical; the player swaps to the real
        // aspect ratio as soon as the stream reports its dimensions.
        vertical: true,
        child: _StreamPopupPlayer(url: videoUrl, vertical: true),
      ),
    );
  }
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// Shared popup chrome: dark rounded dialog sized to the video orientation,
/// with a close button overlaid top-right.
class _VideoPopupDialog extends StatelessWidget {
  final bool vertical;
  final Widget child;

  const _VideoPopupDialog({required this.vertical, required this.child});

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.of(context).size;
    final maxWidth = vertical
        ? (screen.height * 0.8 * 9 / 16).clamp(240.0, screen.width * 0.95)
        : screen.width.clamp(0.0, 800.0) * 0.95;

    return Dialog(
      backgroundColor: Colors.black,
      insetPadding: const EdgeInsets.all(16),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: maxWidth.toDouble(),
          maxHeight: screen.height * 0.85,
        ),
        child: Stack(
          children: [
            child,
            Positioned(
              top: 4,
              right: 4,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 22),
                style: IconButton.styleFrom(
                  backgroundColor: Colors.black45,
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _YoutubePopupPlayer extends StatefulWidget {
  final String videoId;
  final double aspectRatio;

  const _YoutubePopupPlayer({required this.videoId, required this.aspectRatio});

  @override
  State<_YoutubePopupPlayer> createState() => _YoutubePopupPlayerState();
}

class _YoutubePopupPlayerState extends State<_YoutubePopupPlayer> {
  late final YoutubePlayerController _controller;

  @override
  void initState() {
    super.initState();
    _controller = YoutubePlayerController.fromVideoId(
      videoId: widget.videoId,
      autoPlay: true,
      params: const YoutubePlayerParams(showFullscreenButton: true),
    );
  }

  @override
  void dispose() {
    _controller.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return YoutubePlayer(
      controller: _controller,
      aspectRatio: widget.aspectRatio,
    );
  }
}

/// Re-open the Reddit/og:video popup for a media_kit player that was floating in
/// the PiP window, ADOPTING it (no re-buffer). Called by the PiP window's
/// dock-back button (`PipOverlayHost`).
void showAdoptedStreamPopup(
  BuildContext context,
  Player player,
  VideoController controller, {
  bool vertical = false,
}) {
  showDialog<void>(
    context: context,
    builder: (_) => _VideoPopupDialog(
      vertical: vertical,
      child: _StreamPopupPlayer(
        adoptPlayer: player,
        adoptController: controller,
        vertical: vertical,
      ),
    ),
  );
}

/// media_kit player for a direct network stream (Reddit HLS, og:video mp4).
/// Adapts its aspect ratio once the stream reports real dimensions. Can be
/// minimized into the floating PiP window, and re-created in "adopt" mode when
/// docked back (reusing the live player instead of re-buffering).
class _StreamPopupPlayer extends ConsumerStatefulWidget {
  /// Stream URL for a fresh player; null when [adoptPlayer] is supplied.
  final String? url;

  /// An existing player to adopt (docked back from PiP) instead of creating one.
  final Player? adoptPlayer;
  final VideoController? adoptController;
  final bool vertical;

  const _StreamPopupPlayer({
    this.url,
    this.adoptPlayer,
    this.adoptController,
    this.vertical = false,
  }) : assert(url != null || (adoptPlayer != null && adoptController != null));

  @override
  ConsumerState<_StreamPopupPlayer> createState() => _StreamPopupPlayerState();
}

class _StreamPopupPlayerState extends ConsumerState<_StreamPopupPlayer> {
  late final Player _player;
  late final VideoController _controller;
  StreamSubscription<String>? _errorSub;
  String? _error;

  /// True once the player was handed to the PiP window — dispose must NOT tear
  /// it down then (ownership moved).
  bool _releasedToPip = false;

  @override
  void initState() {
    super.initState();
    if (widget.adoptPlayer != null) {
      // Docked back from PiP: reuse the live player (already streaming).
      _player = widget.adoptPlayer!;
      _controller = widget.adoptController!;
    } else {
      _player = Player();
      // Platform-conditional rendering (see [useSoftwareVideoRendering]):
      // software everywhere (Linux GL composites blank frames) except iOS, where
      // the SW renderer hits a libmpv assert → hardware there.
      _controller = VideoController(
        _player,
        configuration: VideoControllerConfiguration(
          enableHardwareAcceleration: !useSoftwareVideoRendering,
        ),
      );
      _player.open(Media(widget.url!));
    }
    _errorSub = _player.stream.error.listen((e) {
      logger.warning('Link video playback failed ($e)', tag: 'LinkVideoPopup');
      if (mounted) setState(() => _error = e);
    });
  }

  @override
  void dispose() {
    _errorSub?.cancel();
    if (!_releasedToPip) _player.dispose();
    super.dispose();
  }

  /// Minimize this stream into the floating PiP window: hand the live player to
  /// the [PipController] and close the dialog. The window keeps it playing and
  /// its dock-back button re-opens this popup via [showAdoptedStreamPopup].
  void _promoteToPip() {
    final w = _player.state.width;
    final h = _player.state.height;
    final aspect = (w != null && h != null && w > 0 && h > 0) ? w / h : null;
    ref.read(pipControllerProvider).promote(PipVideo(
          player: _player,
          controller: _controller,
          name: 'video',
          aspect: aspect,
          isLinkVideo: true,
          vertical: widget.vertical,
        ));
    _releasedToPip = true;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return SizedBox(
        height: 160,
        child: Center(
          child: Text(
            'media.load_error'.tr(),
            style: const TextStyle(color: Colors.white70),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return StreamBuilder<VideoParams>(
      stream: _player.stream.videoParams,
      builder: (context, snapshot) {
        final w = snapshot.data?.dw ?? 0;
        final h = snapshot.data?.dh ?? 0;
        final aspect = (w > 0 && h > 0) ? w / h : 9 / 16;
        return AspectRatio(
          aspectRatio: aspect.toDouble(),
          child: Stack(
            children: [
              Video(
                controller: _controller,
                fit: BoxFit.contain,
                controls: AdaptiveVideoControls,
              ),
              // Minimize-to-PiP, top-left (close stays top-right in the chrome).
              Positioned(
                top: 4,
                left: 4,
                child: IconButton(
                  icon: const Icon(Icons.picture_in_picture_alt,
                      color: Colors.white, size: 22),
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.black45,
                    visualDensity: VisualDensity.compact,
                  ),
                  tooltip: 'media.pip_open'.tr(),
                  onPressed: _promoteToPip,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
