// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../media_attachment.dart';
import '../image_guard.dart';
import 'elastic_image_view.dart';
import 'fullscreen_image_viewer.dart';
import 'media_action_button.dart';
import 'media_message_view.dart';

/// Swipeable fullscreen gallery for a media album (#109). Image pages get
/// pinch/double-tap zoom via [ElasticImageView] (CHAT-56); video/audio/file pages reuse the
/// inline players (`MediaMessageView`) centered on black — a video's own
/// media_kit controls (incl. its fullscreen button) handle playback, and
/// `activeVideoRegistry` keeps only one player running across swipes.
class MediaGalleryScreen extends ConsumerStatefulWidget {
  final List<MediaAttachment> items;
  final int initialIndex;

  const MediaGalleryScreen({
    super.key,
    required this.items,
    this.initialIndex = 0,
  });

  @override
  ConsumerState<MediaGalleryScreen> createState() => _MediaGalleryScreenState();
}

class _MediaGalleryScreenState extends ConsumerState<MediaGalleryScreen> {
  late final PageController _pageController = PageController(
    initialPage: widget.initialIndex,
  );
  late int _current = widget.initialIndex;

  // Current page's zoom state — swipe-down-to-dismiss and paging are only
  // armed at base scale, so panning a zoomed image isn't hijacked.
  bool _zoomed = false;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  /// Page by [delta] (±1). Used by the video page's own swipe handler: a filling
  /// video's media_kit controls would otherwise swallow the horizontal drag, so
  /// we translate it into gallery navigation ourselves.
  void _page(int delta) {
    final target = _current + delta;
    if (target < 0 || target >= widget.items.length) return;
    _pageController.animateToPage(
      target,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    final currentItem = items[_current];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: items.length > 1
            ? Text(
                '${_current + 1} / ${items.length}',
                style: const TextStyle(fontSize: 16),
              )
            : null,
        actions: [
          // Save/share for the current IMAGE (its bytes are already decrypted
          // for display, so this is free). Video/audio/file pages carry their
          // own action button inside the reused inline player.
          if (currentItem.mediaType == MediaType.image)
            _ImageAction(attachment: currentItem),
        ],
      ),
      body: SwipeDownToDismiss(
        enabled: !_zoomed,
        child: PageView.builder(
          controller: _pageController,
          // A zoomed picture pans; the gallery must not take that drag over.
          physics: _zoomed
              ? const NeverScrollableScrollPhysics()
              : const PageScrollPhysics(),
          itemCount: items.length,
          onPageChanged: (i) => setState(() {
            _current = i;
            _zoomed = false; // fresh page starts unzoomed
          }),
          itemBuilder: (context, index) {
            final item = items[index];
            if (item.mediaType == MediaType.image) {
              return _GalleryImagePage(
                attachment: item,
                onZoomChanged: (zoomed) {
                  if (index == _current) setState(() => _zoomed = zoomed);
                },
              );
            }
            // Video: fill the page (expand) so it's shown big, but keep left/right
            // paging even OVER the video. A GestureDetector loses the gesture arena
            // to media_kit's own recognizers, so paging worked only in the black
            // margin. [_SwipeVideoPage] uses a raw Listener (outside the arena) to
            // detect a horizontal swipe on the video itself → page; tap (play/pause)
            // and the bottom seek bar are left to media_kit. media_kit's fullscreen
            // button still opens true fullscreen (where not-swiping is expected).
            if (item.mediaType == MediaType.video) {
              return _SwipeVideoPage(
                onSwipe: _page,
                child: MediaMessageView(attachment: item, expand: true),
              );
            }
            // Audio / file: compact card centered on black; the margin stays
            // swipeable.
            return Center(child: MediaMessageView(attachment: item));
          },
        ),
      ),
    );
  }
}

/// Wraps a filling gallery video so a horizontal swipe over the video pages the
/// gallery. A `GestureDetector` here loses the gesture arena to media_kit's own
/// recognizers (paging then only worked in the black margin), so this uses a raw
/// [Listener] — which receives pointer events regardless of arena outcome — and
/// derives the swipe itself. Taps (play/pause) and drags on the bottom seek bar
/// are left to media_kit: a tap has ~no horizontal delta, and swipes starting on
/// the seek-bar strip are ignored so scrubbing still works.
class _SwipeVideoPage extends StatefulWidget {
  final Widget child;

  /// Called with +1 (next) / -1 (previous) on a horizontal swipe.
  final void Function(int delta) onSwipe;

  const _SwipeVideoPage({required this.child, required this.onSwipe});

  @override
  State<_SwipeVideoPage> createState() => _SwipeVideoPageState();
}

class _SwipeVideoPageState extends State<_SwipeVideoPage> {
  Offset? _down;
  double _height = 0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _height = constraints.maxHeight;
        return Listener(
          onPointerDown: (e) => _down = e.localPosition,
          onPointerCancel: (_) => _down = null,
          onPointerUp: (e) {
            final start = _down;
            _down = null;
            if (start == null) return;
            // Leave the bottom seek-bar strip to media_kit (scrubbing).
            if (_height > 0 && start.dy > _height - 72) return;
            final dx = e.localPosition.dx - start.dx;
            final dy = e.localPosition.dy - start.dy;
            // Clearly-horizontal fling → page; small moves stay taps.
            if (dx.abs() > 48 && dx.abs() > dy.abs() * 1.5) {
              widget.onSwipe(dx < 0 ? 1 : -1);
            }
          },
          child: widget.child,
        );
      },
    );
  }
}

/// One zoomable image page: decrypts on demand and shows the bytes.
class _GalleryImagePage extends ConsumerWidget {
  final MediaAttachment attachment;
  final ValueChanged<bool> onZoomChanged;

  const _GalleryImagePage({
    required this.attachment,
    required this.onZoomChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(decryptedMediaProvider(attachment));
    return async.when(
      loading: () => const Center(
        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
      ),
      error: (e, _) => Center(
        child: Text(
          'media.load_error'.tr(),
          style: const TextStyle(color: Colors.white70),
        ),
      ),
      data: (bytes) => FutureBuilder<bool>(
        // The header check first: a picture too big to decode is not
        // decoded (CHAT-39, C5).
        future: imageSafeToDecodeOnce(bytes),
        builder: (context, safe) => switch (safe.data) {
          true => ElasticImageView(
              image: GuardedMemoryImage.provider(bytes),
              heroTag: attachment.path,
              onZoomChanged: onZoomChanged,
            ),
          false => const Center(
              child: Icon(Icons.broken_image_outlined, color: Colors.white70),
            ),
          null => const SizedBox.shrink(),
        },
      ),
    );
  }
}

/// App-bar save/share button bound to the current image (bytes already cached
/// by the display watch, so no extra decrypt).
class _ImageAction extends ConsumerWidget {
  final MediaAttachment attachment;

  const _ImageAction({required this.attachment});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(decryptedMediaProvider(attachment));
    return async.maybeWhen(
      data: (bytes) => MediaActionButton(
        attachment: attachment,
        bytes: bytes,
        color: Colors.white,
      ),
      orElse: () => const SizedBox.shrink(),
    );
  }
}
