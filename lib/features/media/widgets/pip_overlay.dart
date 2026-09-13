// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

import '../../../core/logging/logger_service.dart';
import '../../../core/navigation/navigation_provider.dart';
import '../../../core/notifications/active_chat_provider.dart';
import '../../chats/chats_controller.dart';
import '../pip_controller.dart';

/// Hosts the floating picture-in-picture window above every route. Placed in
/// `app.dart`'s `builder` (inside the notification overlay, under the lock gate)
/// so the window — and its still-playing media_kit player — survives scrolling,
/// chat switches, and navigation. Renders nothing until a video is promoted.
class PipOverlayHost extends ConsumerWidget {
  final Widget child;

  const PipOverlayHost({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasVideo = ref.watch(
      pipControllerProvider.select((c) => c.hasVideo),
    );
    return Stack(
      children: [
        child,
        if (hasVideo) const _PipWindow(),
      ],
    );
  }
}

/// Margin between the floating window and the screen edges. The window size
/// itself is format-aware (see `_windowSize`).
const double _pipMargin = 12;

/// Extra strip above a YouTube PiP window for its dock/close bar — the iframe is
/// a platform view that draws over Flutter overlays, so controls can't sit on it.
const double _ytBarHeight = 30;

class _PipWindow extends ConsumerStatefulWidget {
  const _PipWindow();

  @override
  ConsumerState<_PipWindow> createState() => _PipWindowState();
}

class _PipWindowState extends ConsumerState<_PipWindow> {
  /// Top-left while a drag is in progress; null → resting at [PipController.corner].
  Offset? _dragTopLeft;

  /// Maximize toggle (W1): near-fullscreen (screen minus safe areas), pinned —
  /// ONE code path for media_kit AND YouTube. Deliberately not the iframe's own
  /// fullscreen (platform-view z-order mess); restore returns to the corner.
  bool _maximized = false;

  void _toggleMaximized() {
    setState(() {
      _maximized = !_maximized;
      _dragTopLeft = null;
    });
    _showControls();
  }

  /// Controls (top strip + center play/pause) fade in on interaction and auto-
  /// hide after a few seconds, like a normal video player.
  bool _controlsVisible = true;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _scheduleHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  void _showControls() {
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  Size _windowSize(double? aspect) {
    final ar = (aspect != null && aspect > 0) ? aspect : 16 / 9;
    if (ar >= 1) {
      // Landscape: a comfortably wide window; height follows the aspect.
      const w = 240.0;
      return Size(w, w / ar); // 16:9 → 240×135
    }
    // Portrait: a bit wider than a phone-narrow strip, height follows the aspect
    // (bounded so a tall clip doesn't fill the screen).
    const w = 190.0;
    final h = (w / ar).clamp(220.0, 340.0);
    return Size(w, h); // 9:16 → 190×338
  }

  Offset _restingTopLeft(PipCorner corner, Size window, Size screen,
      EdgeInsets safe) {
    final left = _pipMargin + safe.left;
    final top = _pipMargin + safe.top;
    final right = screen.width - window.width - _pipMargin - safe.right;
    final bottom = screen.height - window.height - _pipMargin - safe.bottom;
    switch (corner) {
      case PipCorner.topLeft:
        return Offset(left, top);
      case PipCorner.topRight:
        return Offset(right, top);
      case PipCorner.bottomLeft:
        return Offset(left, bottom);
      case PipCorner.bottomRight:
        return Offset(right, bottom);
    }
  }

  /// Dock the floating video back into its chat bubble: re-adopt (route to the
  /// chat first if needed). Works for chat videos, Reddit/og streams (live
  /// re-adopt) and YouTube ([youtubeStart] resumes the fresh controller) — all
  /// carry a chatId/messageId and re-adopt via the messageId match.
  void _dockToChat(String? chatId, {double? youtubeStart}) {
    final activeChat = ref.read(activeChatProvider);
    if (chatId != null && activeChat != chatId) {
      final chats = ref.read(chatsControllerProvider);
      final chat = chats.where((c) => c.id == chatId).firstOrNull;
      if (chat != null) {
        ref.read(navigationServiceProvider).navigateToChat(chat);
      }
    }
    ref.read(pipControllerProvider).requestDock(youtubeStart: youtubeStart);
  }

  @override
  Widget build(BuildContext context) {
    final pip = ref.watch(pipControllerProvider);
    final video = pip.video;
    final yt = pip.youtube;
    if (video == null && yt == null) return const SizedBox.shrink();

    final media = MediaQuery.of(context);
    final screen = media.size;
    final safe = media.padding;
    final Size window;
    final Offset topLeft;
    if (_maximized) {
      // Near-fullscreen: everything inside the safe areas minus the margin,
      // pinned (drag disabled — there is nowhere to go).
      window = Size(
        screen.width - safe.left - safe.right - 2 * _pipMargin,
        screen.height - safe.top - safe.bottom - 2 * _pipMargin,
      );
      topLeft = Offset(safe.left + _pipMargin, safe.top + _pipMargin);
    } else {
      final baseWindow = _windowSize(video?.aspect ?? yt?.aspect);
      // YouTube needs the extra strip for its control bar.
      window = yt != null
          ? Size(baseWindow.width, baseWindow.height + _ytBarHeight)
          : baseWindow;
      topLeft =
          _dragTopLeft ?? _restingTopLeft(pip.corner, window, screen, safe);
    }

    return Positioned(
      left: topLeft.dx,
      top: topLeft.dy,
      width: window.width,
      height: window.height,
      child: GestureDetector(
        onTap: _showControls,
        onPanStart: _maximized
            ? null
            : (_) {
                _showControls();
                setState(() => _dragTopLeft = topLeft);
              },
        onPanUpdate: _maximized
            ? null
            : (d) {
                final next = (_dragTopLeft ?? topLeft) + d.delta;
                setState(() {
                  _dragTopLeft = Offset(
                    next.dx.clamp(
                        safe.left, screen.width - window.width - safe.right),
                    next.dy.clamp(
                        safe.top, screen.height - window.height - safe.bottom),
                  );
                });
              },
        onPanEnd: _maximized
            ? null
            : (_) {
                final tl = _dragTopLeft ?? topLeft;
                final center =
                    tl + Offset(window.width / 2, window.height / 2);
                ref
                    .read(pipControllerProvider)
                    .setCorner(nearestCorner(center, screen));
                setState(() => _dragTopLeft = null);
              },
        child: Material(
          elevation: 8,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          color: Colors.black,
          child: yt != null
              // YouTube: a fresh controller in a real control bar (dock/close);
              // the iframe draws over Flutter overlays so controls can't overlay.
              ? _YoutubePipContent(
                  key: ValueKey(yt.youtubeId),
                  youtube: yt,
                  maximized: _maximized,
                  onToggleMaximize: _toggleMaximized,
                  onDock: (pos) => _dockToChat(yt.chatId, youtubeStart: pos),
                  onClose: () => ref.read(pipControllerProvider).close(),
                )
              : Stack(
                  fit: StackFit.expand,
                  children: [
                    // The same media_kit player keeps running here after promotion.
                    Video(
                      controller: video!.controller,
                      controls: (_) => const SizedBox.shrink(),
                      fit: BoxFit.contain,
                    ),
                    // Auto-hiding controls: fade in on tap/drag, out after 3 s.
                    IgnorePointer(
                      ignoring: !_controlsVisible,
                      child: AnimatedOpacity(
                        opacity: _controlsVisible ? 1 : 0,
                        duration: const Duration(milliseconds: 200),
                        child: _controls(video),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _controls(PipVideo video) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const DecoratedBox(
          decoration: BoxDecoration(color: Colors.black26),
        ),
        // Top strip: dock-back + maximize/restore (left), close (right).
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _PipIconButton(
                    // The inverse of "pop-out": collapse the floating video
                    // back into its chat bubble.
                    icon: Icons.close_fullscreen,
                    tooltip: 'media.pip_return'.tr(),
                    onTap: () => _dockToChat(video.chatId),
                  ),
                  _PipIconButton(
                    icon:
                        _maximized ? Icons.fullscreen_exit : Icons.fullscreen,
                    tooltip: (_maximized
                            ? 'media.pip_restore'
                            : 'media.pip_maximize')
                        .tr(),
                    onTap: _toggleMaximized,
                  ),
                ],
              ),
              _PipIconButton(
                icon: Icons.close,
                tooltip: 'media.pip_close'.tr(),
                onTap: () => ref.read(pipControllerProvider).close(),
              ),
            ],
          ),
        ),
        // Center play/pause, reflecting the live player state.
        Center(
          child: StreamBuilder<bool>(
            stream: video.player.stream.playing,
            initialData: video.player.state.playing,
            builder: (_, snap) {
              final playing = snap.data ?? false;
              return _PipIconButton(
                icon: playing ? Icons.pause : Icons.play_arrow,
                iconSize: 34,
                tooltip: (playing ? 'media.pause' : 'media.play').tr(),
                onTap: () {
                  video.player.playOrPause();
                  _showControls();
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _PipIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final double iconSize;

  const _PipIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.iconSize = 18,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      iconSize: iconSize,
      padding: const EdgeInsets.all(6),
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      visualDensity: VisualDensity.compact,
      tooltip: tooltip,
      icon: Icon(icon, color: Colors.white),
      onPressed: onTap,
    );
  }
}

/// The YouTube PiP window body: builds its OWN fresh [YoutubePlayerController]
/// from the [PipYoutube] data (resuming at its position — the webview can't move
/// live), with an always-visible bar (dock-back + close) above the iframe (which
/// keeps its own play/pause/seek chrome). Docking reads the current position so
/// the bubble resumes there.
class _YoutubePipContent extends StatefulWidget {
  final PipYoutube youtube;
  final void Function(double position) onDock;
  final VoidCallback onClose;

  /// Maximize toggle state + callback — owned by the window (shared with the
  /// media_kit branch), rendered here because the iframe needs its controls in
  /// the bar strip.
  final bool maximized;
  final VoidCallback onToggleMaximize;

  const _YoutubePipContent({
    super.key,
    required this.youtube,
    required this.onDock,
    required this.onClose,
    required this.maximized,
    required this.onToggleMaximize,
  });

  @override
  State<_YoutubePipContent> createState() => _YoutubePipContentState();
}

class _YoutubePipContentState extends State<_YoutubePipContent> {
  late final YoutubePlayerController _controller;

  @override
  void initState() {
    super.initState();
    _controller = YoutubePlayerController.fromVideoId(
      videoId: widget.youtube.youtubeId,
      autoPlay: true,
      startSeconds: widget.youtube.start,
      // No fullscreen in the tiny floating window.
      params: const YoutubePlayerParams(showFullscreenButton: false),
    );
  }

  @override
  void dispose() {
    _controller.close();
    super.dispose();
  }

  Future<void> _dock() async {
    var pos = widget.youtube.start;
    try {
      pos = await _controller.currentTime;
    } catch (e) {
      logger.warning('YouTube PiP currentTime failed: $e', tag: 'PipYoutube');
    }
    widget.onDock(pos);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SizedBox(
          height: _ytBarHeight,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _PipIconButton(
                    icon: Icons.close_fullscreen,
                    tooltip: 'media.pip_return'.tr(),
                    onTap: _dock,
                  ),
                  _PipIconButton(
                    icon: widget.maximized
                        ? Icons.fullscreen_exit
                        : Icons.fullscreen,
                    tooltip: (widget.maximized
                            ? 'media.pip_restore'
                            : 'media.pip_maximize')
                        .tr(),
                    onTap: widget.onToggleMaximize,
                  ),
                ],
              ),
              _PipIconButton(
                icon: Icons.close,
                tooltip: 'media.pip_close'.tr(),
                onTap: widget.onClose,
              ),
            ],
          ),
        ),
        Expanded(
          // YoutubePlayer uses an OverlayPortal (fullscreen plumbing) → it needs
          // an Overlay ancestor. The floating PiP window lives above the app's
          // Navigator (no Overlay in scope), so provide a local one, else the
          // player throws during build (only the webview audio survives).
          child: Overlay(
            initialEntries: [
              OverlayEntry(
                builder: (_) => YoutubePlayer(
                  controller: _controller,
                  aspectRatio: widget.youtube.aspect,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
