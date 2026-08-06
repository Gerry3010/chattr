// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

import '../../../core/logging/logger_service.dart';
import '../../../features/messages/message_links.dart';
import '../active_video_registry.dart';
import '../pip_controller.dart';
import '../video_render_config.dart';

/// The YouTube iframe player rides on webview_flutter, which has no
/// Linux/Windows implementation — there the thumbnail keeps opening the link
/// externally instead of playing inline.
bool get youtubeInlineSupported =>
    kIsWeb ||
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS ||
    defaultTargetPlatform == TargetPlatform.macOS;

/// Whether tapping the preview thumbnail of [uri] can play an inline in-app
/// video on this platform. [videoUrl] is a directly playable stream (Reddit
/// HLS / og:video) resolved by the preview fetch, if any.
bool canPlayLinkInline(Uri uri, String? videoUrl) =>
    videoUrl != null ||
    (youtubeVideoId(uri) != null && youtubeInlineSupported);

/// Inline player for a **link** video inside a chat bubble's preview card.
///
/// Two modes:
///  * [InlineLinkVideoPlayer.stream] — a directly-playable stream (Reddit HLS /
///    og:video) via media_kit. It mirrors [VideoMessagePlayer]'s
///    poster→player→PiP-placeholder lifecycle (minimize into the floating PiP
///    window + dock back into this bubble), keyed by [messageId] so it reuses
///    the exact same PiP machinery a chat video uses.
///  * [InlineLinkVideoPlayer.youtube] — a YouTube/Shorts video via the official
///    iframe player, inline in the bubble. (No PiP in this variant yet.)
///
/// Both register with the [ActiveVideoRegistry], so starting a link video
/// pauses a playing chat video and vice versa.
class InlineLinkVideoPlayer extends ConsumerStatefulWidget {
  /// Directly-playable stream URL (Reddit HLS, og:video mp4) — stream mode.
  final String? streamUrl;

  /// YouTube video id — youtube mode.
  final String? youtubeId;

  /// Preview thumbnail shown on the poster before playback starts.
  final String thumbnailUrl;

  /// Chat + message this link lives in — so the floating window can dock the
  /// player back into this exact bubble (stream mode).
  final String chatId;
  final String messageId;

  /// Display name (a11y / PiP tooltip) and whether the video is portrait
  /// (Reddit videos + YouTube Shorts commonly are) — shapes the box.
  final String title;
  final bool vertical;

  /// Base text color of the surrounding bubble (poster fallback tint).
  final Color textColor;

  const InlineLinkVideoPlayer.stream({
    super.key,
    required String this.streamUrl,
    required this.thumbnailUrl,
    required this.chatId,
    required this.messageId,
    required this.textColor,
    this.title = 'video',
    this.vertical = false,
  }) : youtubeId = null;

  const InlineLinkVideoPlayer.youtube({
    super.key,
    required String this.youtubeId,
    required this.thumbnailUrl,
    required this.chatId,
    required this.messageId,
    required this.textColor,
    this.title = 'video',
    this.vertical = false,
  }) : streamUrl = null;

  @override
  ConsumerState<InlineLinkVideoPlayer> createState() =>
      _InlineLinkVideoPlayerState();
}

class _InlineLinkVideoPlayerState extends ConsumerState<InlineLinkVideoPlayer> {
  // media_kit (stream mode).
  Player? _player;
  VideoController? _controller;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<int?>? _widthSub;
  StreamSubscription<int?>? _heightSub;
  int? _videoWidth;
  int? _videoHeight;

  // YouTube (youtube mode).
  YoutubePlayerController? _ytController;

  /// Cached in [_start]/[_adoptFromPip] so [dispose] can release the active slot
  /// WITHOUT reading `ref` during unmount (see [VideoMessagePlayer._registry]).
  ActiveVideoRegistry? _registry;

  bool _initializing = false;
  String? _error;

  /// True once the stream was handed to the floating PiP window (stream mode).
  bool _promoted = false;

  /// Guards the post-frame dock-back re-adoption against rebuild bursts.
  bool _adopting = false;

  /// The cover image's intrinsic aspect ratio, resolved from the network image
  /// so the poster (and the whole bubble) is sized to the video's real shape
  /// BEFORE playback starts — a portrait Reddit clip no longer jumps from a
  /// 16:9 poster to a tall player. Null until the image decodes.
  double? _thumbAspect;
  ImageStream? _thumbStream;
  ImageStreamListener? _thumbListener;

  bool get _isYoutube => widget.youtubeId != null;

  /// Scroll-under-the-app-bar guard (Android z-order): the YouTube iframe is a
  /// platform view that paints OVER Flutter content — scrolled beneath the chat
  /// app bar it visibly bled through it. We listen to the enclosing scrollable
  /// and, while any part of this bubble sits above the viewport's top edge,
  /// pause the video and swap the webview for a same-sized placeholder (the
  /// controller survives, so scrolling back re-attaches without a page reload).
  /// media_kit videos render as Flutter textures and don't need this.
  ScrollPosition? _scrollPosition;
  bool _hiddenUnderAppBar = false;

  @override
  void initState() {
    super.initState();
    _resolveThumbAspect();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final pos = Scrollable.maybeOf(context)?.position;
    if (!identical(pos, _scrollPosition)) {
      _scrollPosition?.removeListener(_checkAppBarOverlap);
      _scrollPosition = pos?..addListener(_checkAppBarOverlap);
    }
  }

  void _checkAppBarOverlap() {
    if (!mounted || _ytController == null) return;
    final box = context.findRenderObject();
    final viewport = Scrollable.maybeOf(context)?.context.findRenderObject();
    if (box is! RenderBox ||
        !box.attached ||
        viewport is! RenderBox ||
        !viewport.attached) {
      return;
    }
    final intrudes = box.localToGlobal(Offset.zero).dy <
        viewport.localToGlobal(Offset.zero).dy - 1;
    if (intrudes != _hiddenUnderAppBar) {
      if (intrudes) _ytController?.pauseVideo();
      setState(() => _hiddenUnderAppBar = intrudes);
    }
  }

  /// Resolves the cover image's dimensions (shares the ImageCache entry with the
  /// poster's `Image.network`, so it is a single fetch) to drive [_thumbAspect].
  void _resolveThumbAspect() {
    final stream =
        NetworkImage(widget.thumbnailUrl).resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener((info, _) {
      final w = info.image.width;
      final h = info.image.height;
      if (mounted && w > 0 && h > 0) {
        final a = w / h;
        if (a != _thumbAspect) setState(() => _thumbAspect = a);
      }
    }, onError: (_, _) {/* keep the fallback aspect */});
    _thumbStream = stream;
    _thumbListener = listener;
    stream.addListener(listener);
  }

  double? get _videoAspect => (_videoWidth != null &&
          _videoHeight != null &&
          _videoWidth! > 0 &&
          _videoHeight! > 0)
      ? _videoWidth! / _videoHeight!
      : null;

  bool get _isTouch =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  void dispose() {
    _scrollPosition?.removeListener(_checkAppBarOverlap);
    final tl = _thumbListener;
    if (tl != null) _thumbStream?.removeListener(tl);
    _playingSub?.cancel();
    _widthSub?.cancel();
    _heightSub?.cancel();
    final player = _player;
    if (player != null) {
      _registry?.release(player); // field, not ref.read: element is unmounting
    }
    final yt = _ytController;
    if (yt != null) {
      _registry?.releaseExternal(yt);
      yt.close();
    }
    player?.dispose();
    super.dispose();
  }

  // ---- media_kit (stream) ---------------------------------------------------

  Future<void> _start() async {
    if (_initializing || _player != null) return;
    setState(() {
      _initializing = true;
      _error = null;
    });
    try {
      final player = Player();
      final controller = VideoController(
        player,
        configuration: VideoControllerConfiguration(
          enableHardwareAcceleration: !useSoftwareVideoRendering,
        ),
      );
      await player.open(Media(widget.streamUrl!));
      logger.info('🎬 Playing link video ${widget.title}',
          tag: 'InlineLinkVideo');
      if (!mounted) {
        await player.dispose();
        return;
      }
      final registry = ref.read(activeVideoRegistryProvider);
      _registry = registry;
      _playingSub = player.stream.playing.listen((playing) {
        if (playing) {
          registry.setActive(player);
        } else {
          registry.release(player);
        }
      });
      _videoWidth = player.state.width;
      _videoHeight = player.state.height;
      _widthSub = player.stream.width.listen((w) {
        if (mounted && w != null && w > 0 && w != _videoWidth) {
          setState(() => _videoWidth = w);
        }
      });
      _heightSub = player.stream.height.listen((h) {
        if (mounted && h != null && h > 0 && h != _videoHeight) {
          setState(() => _videoHeight = h);
        }
      });
      setState(() {
        _player = player;
        _controller = controller;
        _initializing = false;
      });
    } catch (e) {
      logger.warning('Link video playback failed: $e', tag: 'InlineLinkVideo');
      if (mounted) {
        setState(() {
          _error = e.toString();
          _initializing = false;
        });
      }
    }
  }

  /// Hand this playing stream off to the floating PiP window (stream mode).
  /// `source` is null (network stream); it carries chatId/messageId so it docks
  /// back into THIS bubble via the shared messageId machinery — like a chat video.
  void _promoteToPip() {
    final player = _player;
    final controller = _controller;
    if (player == null || controller == null) return;

    _playingSub?.cancel();
    _widthSub?.cancel();
    _heightSub?.cancel();
    _playingSub = null;
    _widthSub = null;
    _heightSub = null;
    _registry?.release(player);

    ref.read(pipControllerProvider).promote(PipVideo(
          player: player,
          controller: controller,
          name: widget.title,
          aspect: _videoAspect,
          chatId: widget.chatId,
          messageId: widget.messageId,
        ));

    setState(() {
      _player = null;
      _controller = null;
      _promoted = true;
    });
  }

  /// Re-adopt a stream docked back from the PiP window: reuse the SAME live
  /// [Player]/[VideoController] (no re-buffer), re-attach the inline subs.
  void _adoptFromPip(PipVideo v) {
    final player = v.player;
    final registry = ref.read(activeVideoRegistryProvider);
    _registry = registry;
    _playingSub = player.stream.playing.listen((playing) {
      if (playing) {
        registry.setActive(player);
      } else {
        registry.release(player);
      }
    });
    _videoWidth = player.state.width;
    _videoHeight = player.state.height;
    _widthSub = player.stream.width.listen((w) {
      if (mounted && w != null && w > 0 && w != _videoWidth) {
        setState(() => _videoWidth = w);
      }
    });
    _heightSub = player.stream.height.listen((h) {
      if (mounted && h != null && h > 0 && h != _videoHeight) {
        setState(() => _videoHeight = h);
      }
    });
    setState(() {
      _player = player;
      _controller = v.controller;
      _promoted = false;
      _initializing = false;
    });
    registry.setActive(player);
  }

  // ---- YouTube --------------------------------------------------------------

  void _startYoutube() {
    if (_ytController != null) return;
    final controller = YoutubePlayerController.fromVideoId(
      videoId: widget.youtubeId!,
      autoPlay: true,
      params: const YoutubePlayerParams(showFullscreenButton: true),
    );
    // Register so starting this pauses a playing chat/stream video (and it gets
    // paused when one of those starts). Autoplay ≈ starts playing now.
    final registry = ref.read(activeVideoRegistryProvider);
    _registry = registry;
    registry.setActiveExternal(controller, controller.pauseVideo);
    logger.info('🎬 Playing YouTube link ${widget.youtubeId}',
        tag: 'InlineLinkVideo');
    setState(() => _ytController = controller);
  }

  /// Minimize the inline YouTube video into the floating PiP window. The webview
  /// can't move live, so we capture the position, tear down the inline
  /// controller, and let the window build a fresh one that resumes there (a
  /// brief reload). The bubble shows the placeholder until it docks back.
  Future<void> _promoteToPipYoutube() async {
    final controller = _ytController;
    if (controller == null) return;
    var pos = 0.0;
    try {
      pos = await controller.currentTime;
    } catch (_) {/* resume from 0 */}
    if (!mounted) return;
    _registry?.releaseExternal(controller);
    controller.close();
    ref.read(pipControllerProvider).promoteYoutube(PipYoutube(
          youtubeId: widget.youtubeId!,
          name: widget.title,
          start: pos,
          vertical: widget.vertical,
          chatId: widget.chatId,
          messageId: widget.messageId,
        ));
    setState(() {
      _ytController = null; // torn down above → dispose won't double-close
      _promoted = true;
    });
  }

  /// Re-adopt a YouTube video docked back from PiP: build a fresh controller
  /// resuming at the position captured when it was docked (another brief reload).
  void _adoptFromPipYoutube(PipYoutube y) {
    final start = ref.read(pipControllerProvider).dockYoutubeStart ?? y.start;
    final controller = YoutubePlayerController.fromVideoId(
      videoId: y.youtubeId,
      autoPlay: true,
      startSeconds: start,
      params: const YoutubePlayerParams(showFullscreenButton: true),
    );
    final registry = ref.read(activeVideoRegistryProvider);
    _registry = registry;
    registry.setActiveExternal(controller, controller.pauseVideo);
    setState(() {
      _ytController = controller;
      _promoted = false;
      _initializing = false;
    });
  }

  // ---- controls / layout ----------------------------------------------------

  /// Minimize-to-PiP bar above the inline YouTube player. The iframe is an
  /// Android platform view that draws over any Flutter overlay, so the button
  /// can't sit on the video — it lives in a slim strip. Transparent (not a black
  /// bar) so it blends into the bubble; the icon takes the bubble text color.
  /// media_kit players keep their PiP button inside the video controls' top bar.
  Widget _youtubePipBar() {
    return SizedBox(
      height: 32,
      child: Align(
        alignment: Alignment.centerLeft,
        child: IconButton(
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 40, minHeight: 32),
          icon: Icon(Icons.picture_in_picture_alt,
              size: 20, color: widget.textColor),
          tooltip: 'media.pip_open'.tr(),
          onPressed: _promoteToPipYoutube,
        ),
      ),
    );
  }

  MaterialDesktopVideoControlsThemeData _desktopControls() {
    return MaterialDesktopVideoControlsThemeData(
      seekBarMargin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      bottomButtonBarMargin: const EdgeInsets.symmetric(horizontal: 8),
      topButtonBarMargin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      topButtonBar: [
        const Spacer(),
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.picture_in_picture_alt,
              size: 20, color: Colors.white),
          tooltip: 'media.pip_open'.tr(),
          onPressed: _promoteToPip,
        ),
      ],
      bottomButtonBar: const [
        MaterialDesktopPlayOrPauseButton(),
        MaterialDesktopVolumeButton(sliderWidth: 44),
        MaterialDesktopPositionIndicator(),
        Spacer(),
        MaterialDesktopFullscreenButton(),
      ],
    );
  }

  MaterialVideoControlsThemeData _mobileControls({double bottomInset = 0}) {
    return MaterialVideoControlsThemeData(
      seekBarMargin:
          EdgeInsets.only(left: 8, right: 8, top: 4, bottom: 4 + bottomInset),
      bottomButtonBarMargin:
          EdgeInsets.only(left: 8, right: 8, bottom: bottomInset),
      topButtonBarMargin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      topButtonBar: [
        const Spacer(),
        IconButton(
          icon: const Icon(Icons.picture_in_picture_alt,
              size: 22, color: Colors.white),
          tooltip: 'media.pip_open'.tr(),
          onPressed: _promoteToPip,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // Both engines share the PiP dock-back lifecycle, keyed on messageId.
    final pipState = ref.watch(pipControllerProvider
        .select((c) => (dock: c.dockRequested, msg: c.pipMessageId)));
    final pipHoldsThis = pipState.msg == widget.messageId;
    final hasLivePlayer = _controller != null || _ytController != null;

    // Dock-back: the floating window asked to return into THIS bubble.
    if (!hasLivePlayer &&
        !_initializing &&
        !_adopting &&
        pipState.dock &&
        pipHoldsThis) {
      _adopting = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _adopting = false;
        if (!mounted) return;
        final pip = ref.read(pipControllerProvider);
        if (_isYoutube) {
          final y = pip.takeYoutubeForDock();
          if (y != null) _adoptFromPipYoutube(y);
        } else {
          final v = pip.takeForDock();
          if (v != null) _adoptFromPip(v);
        }
      });
    }

    // Our video is currently floating and we hold no live player → placeholder.
    if (pipHoldsThis && !hasLivePlayer) {
      return _pipPlaceholder();
    }
    // The floating video was closed/replaced after we handed it off → poster.
    if (_promoted && !pipHoldsThis) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _promoted) setState(() => _promoted = false);
      });
    }

    // YouTube live player: a PiP bar above the inline iframe (can't overlay the
    // webview). Minimizing reloads a fresh controller in the floating window
    // (the webview can't move live) — see [_promoteToPipYoutube]. While the
    // bubble is scrolled under the app bar the iframe is swapped out (see
    // [_checkAppBarOverlap]) so the platform view can't paint over the bar.
    if (_ytController != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _youtubePipBar(),
          _box(
            _boxAspect,
            _hiddenUnderAppBar
                ? _scrolledAwayPlaceholder()
                : YoutubePlayer(
                    controller: _ytController!, aspectRatio: _boxAspect),
          ),
        ],
      );
    }

    // media_kit live player.
    if (_controller != null) {
      final video = Video(
        controller: _controller!,
        fit: BoxFit.contain,
        controls:
            _isTouch ? MaterialVideoControls : MaterialDesktopVideoControls,
      );
      final Widget themed = _isTouch
          ? MaterialVideoControlsTheme(
              normal: _mobileControls(),
              fullscreen: _mobileControls(
                  bottomInset: MediaQuery.of(context).padding.bottom + 8),
              child: video,
            )
          : MaterialDesktopVideoControlsTheme(
              normal: _desktopControls(),
              fullscreen: _desktopControls(),
              child: video,
            );
      return _box(_boxAspect, themed);
    }
    return _poster(context);
  }

  /// Sizes [child] to [aspect]: fills the card width for landscape, caps
  /// portrait height so a vertical clip does not tower over the chat. Mirrors
  /// the chat-video inline cap (400 max H). Used by the poster, the player and
  /// the PiP placeholder alike so the bubble never jumps between them.
  Widget _box(double aspect, Widget child) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxW =
            constraints.maxWidth.isFinite ? constraints.maxWidth : 300.0;
        var w = maxW;
        var h = w / aspect;
        const maxH = 400.0;
        if (h > maxH) {
          h = maxH;
          w = h * aspect;
        }
        // No own rounding: the parent link-preview card clips (Clip.antiAlias).
        return Center(child: SizedBox(width: w, height: h, child: child));
      },
    );
  }

  /// Aspect to size the box by. YouTube uses its known orientation (its cover
  /// thumbnail is 16:9 even for a vertical Short, so it must not drive sizing);
  /// a stream uses the decoded video's aspect, else the cover image's, else the
  /// portrait/landscape default hint.
  double get _boxAspect {
    if (_isYoutube) return widget.vertical ? 9 / 16 : 16 / 9;
    return _videoAspect ?? _thumbAspect ?? (widget.vertical ? 9 / 16 : 16 / 9);
  }

  /// Same-sized stand-in for the iframe while the bubble sits under the app
  /// bar: the paused thumbnail, dimmed. Swapped back automatically once the
  /// bubble scrolls fully below the viewport's top edge.
  Widget _scrolledAwayPlaceholder() {
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.network(
          widget.thumbnailUrl,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) =>
              const ColoredBox(color: Colors.black87),
        ),
        const ColoredBox(color: Colors.black45),
        const Center(
          child: Icon(Icons.pause_circle_outline,
              size: 36, color: Colors.white70),
        ),
      ],
    );
  }

  /// Static badge shown while this video plays in the floating PiP window.
  Widget _pipPlaceholder() {
    return _box(
      _boxAspect,
      DecoratedBox(
        decoration: const BoxDecoration(color: Colors.black87),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.picture_in_picture_alt,
                size: 36, color: Colors.white70),
            const SizedBox(height: 6),
            Text(
              'media.pip_playing'.tr(),
              style: const TextStyle(color: Colors.white70, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _poster(BuildContext context) {
    final mutedColor = widget.textColor.withValues(alpha: 0.7);
    return GestureDetector(
      onTap: _error != null ? null : (_isYoutube ? _startYoutube : _start),
      child: _box(
        _boxAspect,
        Stack(
          // Loose fit (not expand): only the cover fills the box; the play
          // badge / spinner / error stay their natural size, centered — else
          // StackFit.expand stretches the round play button to a huge circle.
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: Image.network(
                widget.thumbnailUrl,
                fit: BoxFit.cover,
                webHtmlElementStrategy: WebHtmlElementStrategy.fallback,
                errorBuilder: (_, _, _) => ColoredBox(
                  color: widget.textColor.withValues(alpha: 0.06),
                  child: Center(
                      child: Icon(Icons.link, size: 28, color: mutedColor)),
                ),
              ),
            ),
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(color: Colors.black26),
              ),
            ),
            if (_initializing)
              const CircularProgressIndicator(strokeWidth: 2)
            else if (_error != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  'media.load_error'.tr(),
                  style: const TextStyle(color: Colors.white70),
                  textAlign: TextAlign.center,
                ),
              )
            else
              Container(
                decoration: const BoxDecoration(
                  color: Colors.black45,
                  shape: BoxShape.circle,
                ),
                padding: const EdgeInsets.all(6),
                child:
                    const Icon(Icons.play_arrow, size: 36, color: Colors.white),
              ),
          ],
        ),
      ),
    );
  }
}
