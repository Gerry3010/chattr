// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show
        LogicalKeyboardKey,
        SystemChrome,
        SystemUiMode,
        DeviceOrientation;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../core/logging/logger_service.dart';
import '../../../core/security/security_providers.dart';
import '../active_video_registry.dart';
import '../decrypted_media_stream.dart';
import '../media_attachment.dart';
import '../pip_controller.dart';
import '../media_repository.dart';
import '../media_saver.dart';
import '../video_render_config.dart';
import '../video_source.dart';
import 'media_message_view.dart'
    show decryptedMediaProvider, kStandaloneMediaRadius;

/// Inline player for an encrypted video attachment.
///
/// Lazily: shows a poster card with a play button; only when tapped does it
/// download + decrypt the bytes ([decryptedMediaProvider]), materialize a
/// playable [VideoSource] (temp file on native, blob URL on web) and spin up a
/// media_kit player. The source is torn down with the widget so no decrypted
/// video lingers.
/// Downloads + decrypts JUST a video's tiny cover-frame thumbnail (#b), so the
/// poster shows a real frame without streaming the whole video. Null when the
/// sender attached none (non-native/older sender) or on any failure → the
/// poster falls back to the plain black box.
final videoThumbnailProvider =
    FutureProvider.autoDispose.family<Uint8List?, MediaAttachment>(
        (ref, att) async {
  final tp = att.thumbPath;
  final tk = att.thumbKey;
  if (tp == null || tk == null) return null;
  try {
    final repo = ref.read(mediaRepositoryProvider);
    final svc = ref.read(messageEncryptionServiceProvider);
    final blob = await repo.downloadEncrypted(tp);
    return await svc.decryptBytes(blob, base64Decode(tk));
  } catch (_) {
    return null; // poster falls back to the black box
  }
});

class VideoMessagePlayer extends ConsumerStatefulWidget {
  final MediaAttachment attachment;

  /// Fill the parent (fullscreen gallery) instead of the capped inline bubble
  /// box. The gallery keeps horizontal swipe working around it (see
  /// MediaGalleryScreen); here the video just letterboxes to the whole page.
  final bool expand;

  /// Corner radius of the inline box + poster. Standalone media is uniformly
  /// rounded; a captioned video gets corners that nest in the caption bubble
  /// (passed from MediaMessageView). Ignored when [expand] fills the page.
  final BorderRadius cornerRadius;

  const VideoMessagePlayer({
    super.key,
    required this.attachment,
    this.expand = false,
    this.cornerRadius = kStandaloneMediaRadius,
  });

  @override
  ConsumerState<VideoMessagePlayer> createState() =>
      _VideoMessagePlayerState();
}

class _VideoMessagePlayerState extends ConsumerState<VideoMessagePlayer> {
  Player? _player;
  VideoController? _controller;
  VideoSource? _source;
  StreamSubscription<bool>? _playingSub;

  /// The playing video's decoded dimensions (from media_kit), so the inline box
  /// matches the video's aspect ratio instead of a fixed landscape frame — a
  /// portrait clip renders upright, not letterboxed with black side bars.
  StreamSubscription<int?>? _widthSub;
  StreamSubscription<int?>? _heightSub;
  int? _videoWidth;
  int? _videoHeight;

  /// Intrinsic aspect ratio (w/h) once media_kit has decoded the video params,
  /// else null (→ the default box while the poster/spinner shows).
  double? get _videoAspect =>
      (_videoWidth != null &&
              _videoHeight != null &&
              _videoWidth! > 0 &&
              _videoHeight! > 0)
          ? _videoWidth! / _videoHeight!
          : null;

  /// Cached in [_start] so [dispose] can release the active-video slot WITHOUT
  /// touching `ref` — reading a provider in dispose() throws once the
  /// ConsumerStatefulElement is unmounting ("Using ref … is unsafe"), which is
  /// exactly what fired when a PLAYING video scrolled out of the list and its
  /// widget was recycled (the `_player != null` branch below).
  ActiveVideoRegistry? _registry;
  bool _initializing = false;
  String? _error;

  /// True once this player's native objects were handed off to the PiP overlay
  /// ([_promoteToPip]). The fields are nulled on handoff so [dispose] won't tear
  /// down the now-floating player; the inline bubble shows a "playing in PiP"
  /// placeholder instead of a poster (tapping must NOT spin up a second player).
  bool _promoted = false;

  /// Guards the post-frame re-adoption so a burst of rebuilds only schedules the
  /// dock-back once (see [_adoptFromPip]).
  bool _adopting = false;

  /// Chunked-video load progress (0..1) while streaming chunks to the temp file.
  double _progress = 0;

  /// Contexts captured from inside the inline and fullscreen Video subtrees, so
  /// the fullscreen keyboard shortcuts can resolve the correct media_kit state.
  BuildContext? _inlineCtx;
  BuildContext? _fullscreenCtx;

  /// Own focus scope per player. media_kit's controls do `Focus(autofocus:
  /// true)`, which — unscoped — makes every video on screen fight over the
  /// global focus when several are present. Containing each player in its own
  /// scope keeps that autofocus local; we only pull focus to a player when the
  /// user actually starts it.
  final FocusScopeNode _focusScope = FocusScopeNode(debugLabel: 'video-player');

  /// Touch platforms (Android/iOS) need media_kit's *Material* controls: the
  /// Desktop controls are hover-driven, so on a phone tapping never toggles the
  /// overlay and the seek bar can't be scrubbed. Desktop/web keeps the Desktop
  /// controls (+ keyboard shortcuts). Web-safe: uses `defaultTargetPlatform`,
  /// not `dart:io` (this widget also builds for web).
  bool get _isTouch =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  void dispose() {
    _playingSub?.cancel();
    _widthSub?.cancel();
    _heightSub?.cancel();
    final player = _player;
    if (player != null) {
      // Field, not ref.read: the element is unmounting here (see [_registry]).
      _registry?.release(player);
    }
    _focusScope.dispose();
    player?.dispose();
    _source?.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (_initializing || _player != null) return;
    setState(() {
      _initializing = true;
      _error = null;
    });
    try {
      final att = widget.attachment;
      final VideoSource source;
      if (att.isChunked && !kIsWeb) {
        // Play WHILE it loads (1.27): the player opens a local address and gets
        // every 6 MB block as soon as it is there AND verified. Before it was
        // the other way round — fetch and decrypt everything, then open; with
        // 80 MB that was several seconds of standstill, and incidentally the
        // video lay decrypted on disk meanwhile. Both are gone with this.
        final repo = ref.read(mediaRepositoryProvider);
        final svc = ref.read(messageEncryptionServiceProvider);
        source = await VideoSource.streaming(att, repo, svc);
      } else if (att.isChunked) {
        // Browser: no local server, no file path — the blocks travel into a
        // blob as before.
        final repo = ref.read(mediaRepositoryProvider);
        final svc = ref.read(messageEncryptionServiceProvider);
        final stream = decryptedMediaChunks(att, repo, svc, onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        });
        source = await VideoSource.fromChunkStream(stream, att.name, att.mime);
      } else {
        final bytes = await ref.read(decryptedMediaProvider(att).future);
        source = await VideoSource.create(bytes, att.name, att.mime);
      }
      final player = Player();
      // Software rendering: media_kit's hardware GL path renders a blank/blue
      // texture under Flutter desktop on Linux/XWayland (the decoded frames
      // never composite). A software pixel buffer paints reliably everywhere.
      final controller = VideoController(
        player,
        configuration: VideoControllerConfiguration(
          enableHardwareAcceleration: !useSoftwareVideoRendering,
        ),
      );
      await player.open(Media(source.uri));
      logger.info(
        '🎬 Playing video ${widget.attachment.name}',
        tag: 'VideoMessagePlayer',
      );
      if (!mounted) {
        await player.dispose();
        await source.dispose();
        return;
      }
      // Single-active-video: when THIS player transitions to playing, pause
      // any other inline video that was running. Cache the registry so dispose()
      // can release the slot without reading `ref` during unmount.
      final registry = ref.read(activeVideoRegistryProvider);
      _registry = registry;
      _playingSub = player.stream.playing.listen((playing) {
        if (playing) {
          registry.setActive(player);
        } else {
          registry.release(player);
        }
      });
      // Track the decoded video size so the inline box adopts the real aspect
      // ratio (portrait clips render upright instead of letterboxed). Seed from
      // the current state in case params are already known.
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
        _source = source;
        _player = player;
        _controller = controller;
        _initializing = false;
      });
      // The user just started THIS video → give it keyboard focus so the
      // shortcuts work, without other players having stolen it on render.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusScope.requestFocus();
      });
    } catch (e) {
      logger.warning('Video playback failed: $e', tag: 'VideoMessagePlayer');
      if (mounted) {
        setState(() {
          _error = e.toString();
          _initializing = false;
        });
      }
    }
  }

  /// Hand this playing video off to the floating PiP window. Ownership of the
  /// native [Player]/[VideoController]/[VideoSource] moves to the [PipController]
  /// (which keeps them alive above the Navigator); this widget nulls its own
  /// references so its [dispose] won't tear them down, cancels its inline
  /// subscriptions, releases the single-active slot, and renders a placeholder.
  void _promoteToPip() {
    final player = _player;
    final controller = _controller;
    final source = _source;
    if (player == null || controller == null || source == null) return;

    _playingSub?.cancel();
    _widthSub?.cancel();
    _heightSub?.cancel();
    _playingSub = null;
    _widthSub = null;
    _heightSub = null;
    _registry?.release(player);

    final ids = widget.attachment.storageIds;
    ref.read(pipControllerProvider).promote(PipVideo(
          player: player,
          controller: controller,
          source: source,
          name: widget.attachment.name,
          aspect: _videoAspect,
          chatId: ids?.chatId,
          messageId: ids?.messageId,
        ));

    // Relinquish ownership: nulled fields make dispose() skip these objects.
    setState(() {
      _player = null;
      _controller = null;
      _source = null;
      _promoted = true;
    });
  }

  /// Re-adopt a video that was docked back from the PiP window: reuse the exact
  /// same [Player]/[VideoController]/[VideoSource] (never re-decrypt), re-attach
  /// the inline subscriptions, and render it in place. The inverse of
  /// [_promoteToPip].
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
      _source = v.source;
      _player = player;
      _controller = v.controller;
      _promoted = false;
      _initializing = false;
    });
    // This player is the active one again (it kept playing in PiP).
    registry.setActive(player);
  }

  /// Lazily download + decrypt the bytes, then hand off to the OS share sheet
  /// (native) or trigger a browser download (web).
  Future<void> _saveOrShare() async {
    final att = widget.attachment;
    try {
      if (att.isChunked) {
        // Stream the chunks to a temp file, then share/save that file — never
        // the whole video in RAM.
        final repo = ref.read(mediaRepositoryProvider);
        final svc = ref.read(messageEncryptionServiceProvider);
        final src = await VideoSource.fromChunkStream(
            decryptedMediaChunks(att, repo, svc), att.name, att.mime);
        try {
          await saveOrShareMediaPath(
              sourcePath: src.uri, fileName: att.name, mimeType: att.mime);
        } finally {
          await src.dispose();
        }
      } else {
        final bytes = await ref.read(decryptedMediaProvider(att).future);
        await saveOrShareMedia(
            fileName: att.name, mimeType: att.mime, bytes: bytes);
      }
      logger.info(
        'Video ${mediaUsesShareSheet ? 'shared' : 'downloaded'}: ${att.name}',
        tag: 'VideoMessagePlayer',
      );
    } catch (e) {
      logger.error('Video save/share failed: $e', tag: 'VideoMessagePlayer');
    }
  }

  /// Keyboard shortcuts for the video. Keeps media_kit's desktop defaults
  /// (space = play/pause, ↑/↓ = volume, F = fullscreen, Esc = exit) intact and
  /// adds the requested bindings: F11 toggles fullscreen, ←/→ seek ±5s (the
  /// built-in default is only ±2s). Media ops use [_player] directly.
  ///
  /// Fullscreen ops need a context from *inside* the Video subtree, kept
  /// separately for the inline vs fullscreen instances ([_inlineCtx] /
  /// [_fullscreenCtx]): a single shared context is unreliable because the inline
  /// controls rebuild several times a second (position indicator) and would
  /// clobber it while fullscreen is open, breaking Esc/F. [_fullscreenCtx] is
  /// only mounted while the fullscreen route is up, so its mounted +
  /// [isFullscreen] state is the source of truth.
  Map<ShortcutActivator, VoidCallback> _videoShortcuts() {
    final player = _player;
    if (player == null) return const <ShortcutActivator, VoidCallback>{};

    void seekBy(int seconds) {
      final dur = player.state.duration;
      var target = player.state.position + Duration(seconds: seconds);
      if (target < Duration.zero) target = Duration.zero;
      if (dur > Duration.zero && target > dur) target = dur;
      player.seek(target);
    }

    void bumpVolume(double delta) =>
        player.setVolume((player.state.volume + delta).clamp(0.0, 100.0));

    bool inFullscreen() {
      final fs = _fullscreenCtx;
      return fs != null && fs.mounted && isFullscreen(fs);
    }

    void toggleFs() {
      if (inFullscreen()) {
        exitFullscreen(_fullscreenCtx!);
      } else {
        final inl = _inlineCtx;
        if (inl != null && inl.mounted) enterFullscreen(inl);
      }
    }

    void exitFs() {
      if (inFullscreen()) exitFullscreen(_fullscreenCtx!);
    }

    return <ShortcutActivator, VoidCallback>{
      // Toggle/exit (and play-pause) must NOT auto-repeat: SingleActivator
      // defaults to includeRepeats:true, so holding a letter key like F even
      // briefly fires the callback several times → fullscreen toggles on/off
      // repeatedly and appears to "do nothing". F11 (a function key) is tapped
      // cleanly so it only fired once — which is why it worked and F didn't.
      const SingleActivator(LogicalKeyboardKey.space, includeRepeats: false):
          player.playOrPause,
      const SingleActivator(LogicalKeyboardKey.arrowUp): () => bumpVolume(10),
      const SingleActivator(LogicalKeyboardKey.arrowDown): () => bumpVolume(-10),
      const SingleActivator(LogicalKeyboardKey.arrowLeft): () => seekBy(-5),
      const SingleActivator(LogicalKeyboardKey.arrowRight): () => seekBy(5),
      const SingleActivator(LogicalKeyboardKey.keyF, includeRepeats: false):
          toggleFs,
      const SingleActivator(LogicalKeyboardKey.f11, includeRepeats: false):
          toggleFs,
      const SingleActivator(LogicalKeyboardKey.escape, includeRepeats: false):
          exitFs,
    };
  }

  MaterialDesktopVideoControlsThemeData _controlsTheme({
    required bool fullscreen,
  }) {
    return MaterialDesktopVideoControlsThemeData(
      seekBarMargin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      bottomButtonBarMargin: const EdgeInsets.symmetric(horizontal: 8),
      topButtonBarMargin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      keyboardShortcuts: _videoShortcuts(),
      // Download/share stays reachable after playback starts: the poster's
      // button is gone once the Video mounts, so surface it in the controls'
      // top bar (appears on hover, top-right).
      topButtonBar: [
        const Spacer(),
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.picture_in_picture_alt,
              size: 20, color: Colors.white),
          tooltip: 'media.pip_open'.tr(),
          onPressed: _promoteToPip,
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: Icon(mediaUsesShareSheet ? Icons.ios_share : Icons.download,
              size: 20, color: Colors.white),
          tooltip: (mediaUsesShareSheet ? 'media.share' : 'media.download').tr(),
          onPressed: _saveOrShare,
        ),
      ],
      bottomButtonBar: [
        const MaterialDesktopPlayOrPauseButton(),
        // Inline bar is narrow: a short volume slider keeps the hover-expanded
        // state from overflowing the bubble; fullscreen gets the full slider.
        MaterialDesktopVolumeButton(sliderWidth: fullscreen ? 80 : 44),
        const MaterialDesktopPositionIndicator(),
        const Spacer(),
        const MaterialDesktopFullscreenButton(),
        // Capture this controls instance's own context (inside the Video
        // subtree) so the fullscreen shortcuts resolve the correct video state.
        Builder(builder: (ctx) {
          if (fullscreen) {
            _fullscreenCtx = ctx;
          } else {
            _inlineCtx = ctx;
          }
          return const SizedBox.shrink();
        }),
      ],
    );
  }

  /// Touch (Android/iOS) controls theme: media_kit's Material controls respond
  /// to tap-to-toggle and drag-to-scrub. Keeps the download/share button in the
  /// top bar; everything else uses the package's mobile defaults (center
  /// play/pause, bottom seek bar + position + fullscreen).
  MaterialVideoControlsThemeData _mobileControlsTheme({double bottomInset = 0}) {
    return MaterialVideoControlsThemeData(
      // Lift the seek bar + button bar above the bottom safe area (iOS home
      // indicator / Android gesture bar) when the video fills the screen — there
      // the seek bar otherwise sits in the system swipe zone and can't be
      // scrubbed. [bottomInset] is 0 for the small inline box (nowhere near it).
      seekBarMargin:
          EdgeInsets.only(left: 8, right: 8, top: 4, bottom: 4 + bottomInset),
      bottomButtonBarMargin: EdgeInsets.only(left: 8, right: 8, bottom: bottomInset),
      topButtonBarMargin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      topButtonBar: [
        const Spacer(),
        IconButton(
          icon: const Icon(Icons.picture_in_picture_alt,
              size: 22, color: Colors.white),
          tooltip: 'media.pip_open'.tr(),
          onPressed: _promoteToPip,
        ),
        IconButton(
          icon: Icon(mediaUsesShareSheet ? Icons.ios_share : Icons.download,
              size: 22, color: Colors.white),
          tooltip: (mediaUsesShareSheet ? 'media.share' : 'media.download').tr(),
          onPressed: _saveOrShare,
        ),
      ],
    );
  }

  /// Fullscreen-enter hook that respects the video's orientation. media_kit's
  /// default ([defaultEnterNativeFullscreen]) hard-locks landscape on mobile,
  /// which sideways-squashes portrait clips. For a portrait video we keep the
  /// device upright (still immersive); landscape videos and desktop keep the
  /// package default. Dimensions come from the decoded stream ([Player.state]).
  Future<void> _enterFullscreen() async {
    final w = _player?.state.width;
    final h = _player?.state.height;
    final isPortraitVideo = w != null && h != null && h > w;
    if (isPortraitVideo && _isTouch) {
      await SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.immersiveSticky,
        overlays: const [],
      );
      await SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
      return;
    }
    await defaultEnterNativeFullscreen();
  }

  /// Exit hook: restore the system UI + free the orientation lock (mirrors the
  /// package default, used for both portrait and landscape).
  Future<void> _exitFullscreen() => defaultExitNativeFullscreen();

  @override
  Widget build(BuildContext context) {
    // Watch only the PiP fields relevant to a bubble (not corner/drag churn).
    final pipState = ref.watch(pipControllerProvider.select(
        (c) => (dock: c.dockRequested, msg: c.video?.messageId)));
    final mine = widget.attachment.storageIds?.messageId;
    final pipHoldsThis = mine != null && pipState.msg == mine;

    // Dock-back: the floating window asked to return into THIS bubble → re-adopt
    // the live player (reuse it, never re-decrypt). Handles both the bubble that
    // promoted it and a fresh bubble built after navigating back to the chat.
    if (_player == null &&
        !_initializing &&
        !_adopting &&
        pipState.dock &&
        pipHoldsThis) {
      _adopting = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _adopting = false;
        if (!mounted) return;
        final v = ref.read(pipControllerProvider).takeForDock();
        if (v != null) _adoptFromPip(v);
      });
    }

    // This bubble's video is currently in the floating window (promoted, still
    // floating, or mid-dock) and we don't hold a live player → show the "playing
    // in PiP" placeholder, never a second play poster (which would re-decrypt).
    if (pipHoldsThis && _controller == null) {
      return _pipPlaceholder(context);
    }
    // The floating video was closed/replaced and we had handed it off → let this
    // bubble play inline again (poster).
    if (_promoted && !pipHoldsThis) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _promoted) setState(() => _promoted = false);
      });
    }
    if (_controller != null) {
      // Touch platforms get the Material controls (tap/scrub); desktop/web keep
      // the Desktop controls + keyboard shortcuts.
      final video = Video(
        controller: _controller!,
        fit: BoxFit.contain,
        controls: _isTouch ? MaterialVideoControls : MaterialDesktopVideoControls,
        onEnterFullscreen: _enterFullscreen,
        onExitFullscreen: _exitFullscreen,
      );
      // Bottom safe-area inset (iOS home indicator / Android gesture bar).
      // Applied to the controls only where the video fills the screen: the
      // fullscreen theme always, and the normal theme only in the gallery
      // (expand). The small inline box keeps its controls flush.
      final safeBottom = MediaQuery.of(context).padding.bottom;
      final normalInset = widget.expand ? safeBottom + 8 : 0.0;
      final fullscreenInset = safeBottom + 8;
      final Widget themed = _isTouch
          ? MaterialVideoControlsTheme(
              normal: _mobileControlsTheme(bottomInset: normalInset),
              fullscreen: _mobileControlsTheme(bottomInset: fullscreenInset),
              child: video,
            )
          : MaterialDesktopVideoControlsTheme(
              normal: _controlsTheme(fullscreen: false),
              fullscreen: _controlsTheme(fullscreen: true),
              child: video,
            );
      final Widget framed = FocusScope(node: _focusScope, child: themed);
      // Fullscreen gallery: fill the page; BoxFit.contain letterboxes to the
      // real aspect. The gallery wraps this in a swipe handler so paging still
      // works over the filling video.
      if (widget.expand) {
        return SizedBox.expand(child: framed);
      }
      // Inline: size the box to the video's real aspect ratio once decoded
      // (portrait clips render upright, not letterboxed in a fixed landscape
      // frame); fall back to the default landscape box while params are unknown.
      final aspect = _videoAspect;
      return ClipRRect(
        borderRadius: widget.cornerRadius,
        child: aspect != null
            ? ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 300, maxHeight: 400),
                child: AspectRatio(aspectRatio: aspect, child: framed),
              )
            : SizedBox(width: 300, height: 205, child: framed),
      );
    }
    return _poster(context);
  }

  // Inline poster box caps — match the playing box so starting the video
  // doesn't resize the bubble (envelope dims already shaped both, #9).
  static const double _posterMaxW = 300;
  static const double _posterMaxH = 400;

  /// The inline poster box, shaped to the sender's intrinsic aspect ratio
  /// (envelope dims, #9) so it doesn't jump when the video starts. Null when the
  /// dimensions are unknown (older/non-native sender) → the caller falls back to
  /// the legacy 300×190 landscape box.
  Size? _reservedPosterSize() {
    final ar = widget.attachment.aspectRatio;
    if (ar == null) return null;
    var w = _posterMaxW;
    var h = w / ar;
    if (h > _posterMaxH) {
      h = _posterMaxH;
      w = h * ar;
    }
    return Size(w, h);
  }

  /// Shown in the chat bubble while this video is playing in the floating PiP
  /// window (ownership handed off). Same box as the poster so the bubble doesn't
  /// resize; a static badge, NOT a play button — starting a new player here
  /// would double the video.
  Widget _pipPlaceholder(BuildContext context) {
    final reserved = widget.expand ? null : _reservedPosterSize();
    return Container(
      width: widget.expand ? double.infinity : (reserved?.width ?? 300),
      height: widget.expand ? double.infinity : (reserved?.height ?? 190),
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: widget.expand ? null : widget.cornerRadius,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.picture_in_picture_alt,
              size: 40, color: Colors.white70),
          const SizedBox(height: 8),
          Text(
            'media.pip_playing'.tr(),
            style: const TextStyle(color: Colors.white70, fontSize: 12),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _poster(BuildContext context) {
    final reserved = widget.expand ? null : _reservedPosterSize();
    // Cover frame behind the play button (#b): decrypted lazily, tiny blob.
    final thumb =
        ref.watch(videoThumbnailProvider(widget.attachment)).asData?.value;
    return GestureDetector(
      onTap: _error != null ? null : _start,
      child: Container(
        // Fill the page in the fullscreen gallery; otherwise the aspect-shaped
        // box (envelope dims) or the legacy landscape fallback.
        width: widget.expand ? double.infinity : (reserved?.width ?? 300),
        height: widget.expand ? double.infinity : (reserved?.height ?? 190),
        decoration: BoxDecoration(
          color: Colors.black87,
          borderRadius: widget.expand ? null : widget.cornerRadius,
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Cover-frame thumbnail filling the poster, with a dark scrim so the
            // white play button + footer stay legible over any frame.
            if (thumb != null) ...[
              Positioned.fill(
                child: Image.memory(thumb, fit: BoxFit.cover),
              ),
              const Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(color: Colors.black26),
                ),
              ),
            ],
            if (_initializing)
              // Chunked videos stream in — show the download %; others just spin.
              (widget.attachment.isChunked
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(strokeWidth: 2),
                        const SizedBox(height: 8),
                        Text(
                          'media.loading_percent'
                              .tr(args: ['${(_progress * 100).round()}']),
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 12),
                        ),
                      ],
                    )
                  : const CircularProgressIndicator(strokeWidth: 2))
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
              const Icon(Icons.play_circle_fill,
                  size: 56, color: Colors.white),
            // Filename + size footer.
            Positioned(
              left: 8,
              right: 8,
              bottom: 6,
              child: Row(
                children: [
                  const Icon(Icons.videocam, size: 16, color: Colors.white70),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      widget.attachment.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 12),
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                        mediaUsesShareSheet ? Icons.ios_share : Icons.download,
                        size: 18,
                        color: Colors.white70),
                    tooltip: (mediaUsesShareSheet ? 'media.share' : 'media.download')
                        .tr(),
                    onPressed: _saveOrShare,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
