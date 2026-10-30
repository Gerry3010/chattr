// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../media_attachment.dart';
import 'elastic_image_view.dart';
import 'media_action_button.dart';
import '../image_guard.dart';

/// Wraps fullscreen media so a downward drag pulls the content down over a
/// fading backdrop and pops the route past a threshold — iOS/Telegram-style
/// swipe-to-dismiss (1.10).
///
/// Uses a raw [Listener] rather than a `GestureDetector` on purpose: the child
/// (InteractiveViewer) claims the drag gesture in the arena, so a
/// GestureDetector only ever fired on the black margin AROUND the image. A
/// Listener receives pointer events regardless of the arena, so the dismiss
/// works while dragging ON the image too. It only commits to a clearly-downward
/// single-finger drag, leaving horizontal (gallery paging) and multi-finger
/// (pinch-zoom) gestures to the child. [enabled] is set false while zoomed so a
/// two-finger/panning interaction on a zoomed image is never hijacked.
class SwipeDownToDismiss extends StatefulWidget {
  final Widget child;

  /// While false, the dismiss gesture is off (e.g. the image is pinch-zoomed).
  final bool enabled;

  /// Backdrop behind the child; its opacity fades out as the drag progresses.
  final Color backgroundColor;

  /// Called instead of the default `Navigator.maybePop()` when dismissed.
  final VoidCallback? onDismiss;

  const SwipeDownToDismiss({
    super.key,
    required this.child,
    this.enabled = true,
    this.backgroundColor = Colors.black,
    this.onDismiss,
  });

  @override
  State<SwipeDownToDismiss> createState() => _SwipeDownToDismissState();
}

class _SwipeDownToDismissState extends State<SwipeDownToDismiss> {
  double _dy = 0; // committed downward drag distance (0 = at rest)
  int _pointers = 0; // live pointer count (>1 = pinch → not a dismiss)
  Offset? _start; // where the single-finger drag began
  bool _committed = false; // locked in to a vertical-dismiss drag
  int _startMs = 0;

  // Pop when dragged past this far OR flicked down quickly.
  static const double _dismissDistance = 130;
  static const double _flickDistance = 60;
  static const int _flickMaxMs = 260;
  // Drag distance over which the backdrop fully fades / content shrinks.
  static const double _travel = 320;
  // Movement needed before we decide the drag is "ours" (vertical) vs the
  // child's (horizontal paging / small taps).
  static const double _slop = 10;

  void _onDown(PointerDownEvent e) {
    _pointers++;
    if (_pointers == 1) {
      _start = e.position;
      _committed = false;
      _startMs = e.timeStamp.inMilliseconds;
    } else {
      // A second finger → pinch-zoom, not a dismiss. Abandon any pending drag.
      _snapBack();
      _start = null;
      _committed = false;
    }
  }

  void _onMove(PointerMoveEvent e) {
    if (!widget.enabled || _pointers != 1 || _start == null) return;
    final dx = e.position.dx - _start!.dx;
    final dy = e.position.dy - _start!.dy;
    if (!_committed) {
      // Ignore until we've moved past the slop, then only take clearly-downward
      // drags; hand horizontal / upward moves back to the child.
      if (dy.abs() < _slop && dx.abs() < _slop) return;
      if (dy > 0 && dy > dx.abs() * 1.2) {
        _committed = true;
      } else {
        _start = null; // not our gesture this time
        return;
      }
    }
    final next = dy.clamp(0.0, 100000.0);
    if (next != _dy) setState(() => _dy = next);
  }

  void _onUp(PointerUpEvent e) {
    _pointers = (_pointers - 1).clamp(0, 1 << 30);
    if (_committed) {
      final elapsed = e.timeStamp.inMilliseconds - _startMs;
      final flicked = _dy >= _flickDistance && elapsed <= _flickMaxMs;
      if (_dy >= _dismissDistance || flicked) {
        (widget.onDismiss ?? () => Navigator.of(context).maybePop())();
      } else {
        _snapBack();
      }
      _committed = false;
    }
    if (_pointers == 0) _start = null;
  }

  void _onCancel(PointerCancelEvent e) {
    _pointers = (_pointers - 1).clamp(0, 1 << 30);
    _committed = false;
    if (_pointers == 0) _start = null;
    _snapBack();
  }

  void _snapBack() {
    if (_dy != 0 && mounted) setState(() => _dy = 0);
  }

  @override
  Widget build(BuildContext context) {
    final progress = (_dy / _travel).clamp(0.0, 1.0);
    final scale = 1 - progress * 0.12;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: _onUp,
      onPointerCancel: _onCancel,
      child: Container(
        color: widget.backgroundColor.withValues(alpha: 1 - progress * 0.85),
        child: Transform.translate(
          offset: Offset(0, _dy),
          child: Transform.scale(scale: scale, child: widget.child),
        ),
      ),
    );
  }
}

/// An [ElasticImageView] that closes with a swipe down while it is not zoomed.
/// The one viewer for photos in chats, albums, and profile and group pictures
/// (CHAT-55/56).
class DismissibleElasticImage extends StatefulWidget {
  final ImageProvider image;
  final Object? heroTag;
  final Color backgroundColor;

  /// Reports the zoom state on, for a surrounding gallery.
  final ValueChanged<bool>? onZoomChanged;

  const DismissibleElasticImage({
    super.key,
    required this.image,
    this.heroTag,
    this.backgroundColor = Colors.black,
    this.onZoomChanged,
  });

  @override
  State<DismissibleElasticImage> createState() =>
      _DismissibleElasticImageState();
}

class _DismissibleElasticImageState extends State<DismissibleElasticImage> {
  bool _zoomed = false;

  @override
  Widget build(BuildContext context) => SwipeDownToDismiss(
        enabled: !_zoomed,
        backgroundColor: widget.backgroundColor,
        child: ElasticImageView(
          image: widget.image,
          heroTag: widget.heroTag,
          onZoomChanged: (zoomed) {
            setState(() => _zoomed = zoomed);
            widget.onZoomChanged?.call(zoomed);
          },
        ),
      );
}

/// Fullscreen single-image viewer: pinch-zoom (fitted to the screen, then bigger)
/// plus swipe-down-to-dismiss.
class FullscreenImageViewer extends StatelessWidget {
  final MediaAttachment attachment;
  final Uint8List bytes;

  const FullscreenImageViewer({
    super.key,
    required this.attachment,
    required this.bytes,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          MediaActionButton(
            attachment: attachment,
            bytes: bytes,
            color: Colors.white,
          ),
        ],
      ),
      body: DismissibleElasticImage(image: GuardedMemoryImage.provider(bytes)),
    );
  }
}

/// Opens [FullscreenImageViewer] as a transparent route so the swipe-down
/// dismiss reveals the chat behind as the image is dragged away.
void openFullscreenImage(
  BuildContext context, {
  required MediaAttachment attachment,
  required Uint8List bytes,
}) async {
  // A picture too big to decode stays closed here too (CHAT-39, C5).
  if (!await imageSafeToDecode(bytes) || !context.mounted) return;
  Navigator.of(context).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 200),
      reverseTransitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (_, _, _) =>
          FullscreenImageViewer(attachment: attachment, bytes: bytes),
      transitionsBuilder: (_, anim, _, child) =>
          FadeTransition(opacity: anim, child: child),
    ),
  );
}
