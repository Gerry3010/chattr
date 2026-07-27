// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../core/navigation/navigation_provider.dart';
import '../../../core/notifications/active_chat_provider.dart';
import '../../../screens/chat/components/link_video_popup.dart';
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

/// Fixed window width; height derives from the video aspect (default 16:9).
const double _pipWidth = 168;
const double _pipMargin = 12;

class _PipWindow extends ConsumerStatefulWidget {
  const _PipWindow();

  @override
  ConsumerState<_PipWindow> createState() => _PipWindowState();
}

class _PipWindowState extends ConsumerState<_PipWindow> {
  /// Top-left while a drag is in progress; null → resting at [PipController.corner].
  Offset? _dragTopLeft;

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
    final h = (_pipWidth / ar).clamp(80.0, 260.0);
    return Size(_pipWidth, h);
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

  /// Dock the floating video back where it came from. A chat video re-adopts the
  /// SAME live player into its bubble (route there first if needed); a link video
  /// re-opens its popup dialog adopting the same player. Never re-decrypts /
  /// re-buffers.
  void _dockBack(PipVideo video) {
    if (video.isLinkVideo) {
      final v = ref.read(pipControllerProvider).detach();
      if (v == null) return;
      final ctx = ref.read(navigationServiceProvider).navigatorKey.currentContext;
      if (ctx == null) {
        // Nowhere to show it — don't leak the native player.
        v.player.dispose();
        return;
      }
      showAdoptedStreamPopup(ctx, v.player, v.controller, vertical: v.vertical);
      return;
    }
    final activeChat = ref.read(activeChatProvider);
    if (video.chatId != null && activeChat != video.chatId) {
      final chats = ref.read(chatsControllerProvider);
      final chat = chats.where((c) => c.id == video.chatId).firstOrNull;
      if (chat != null) {
        ref.read(navigationServiceProvider).navigateToChat(chat);
      }
    }
    ref.read(pipControllerProvider).requestDock();
  }

  @override
  Widget build(BuildContext context) {
    final pip = ref.watch(pipControllerProvider);
    final video = pip.video;
    if (video == null) return const SizedBox.shrink();

    final media = MediaQuery.of(context);
    final screen = media.size;
    final safe = media.padding;
    final window = _windowSize(video.aspect);
    final resting = _restingTopLeft(pip.corner, window, screen, safe);
    final topLeft = _dragTopLeft ?? resting;

    return Positioned(
      left: topLeft.dx,
      top: topLeft.dy,
      width: window.width,
      height: window.height,
      child: GestureDetector(
        onTap: _showControls,
        onPanStart: (_) {
          _showControls();
          setState(() => _dragTopLeft = topLeft);
        },
        onPanUpdate: (d) {
          final next = (_dragTopLeft ?? resting) + d.delta;
          setState(() {
            _dragTopLeft = Offset(
              next.dx.clamp(
                  safe.left, screen.width - window.width - safe.right),
              next.dy.clamp(
                  safe.top, screen.height - window.height - safe.bottom),
            );
          });
        },
        onPanEnd: (_) {
          final tl = _dragTopLeft ?? resting;
          final center = tl + Offset(window.width / 2, window.height / 2);
          ref.read(pipControllerProvider).setCorner(nearestCorner(center, screen));
          setState(() => _dragTopLeft = null);
        },
        child: Material(
          elevation: 8,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          color: Colors.black,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // The same media_kit player keeps running here after promotion.
              Video(
                controller: video.controller,
                controls: (_) => const SizedBox.shrink(),
                fit: BoxFit.contain,
              ),
              // Auto-hiding controls: fade in on tap/drag, fade out after 3 s.
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
        // Top strip: dock-back (left) + close (right).
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _PipIconButton(
                // The inverse of "pop-out": collapse the floating video back
                // into its chat bubble.
                icon: Icons.close_fullscreen,
                tooltip: 'media.pip_return'.tr(),
                onTap: () => _dockBack(video),
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
