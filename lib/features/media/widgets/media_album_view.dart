// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:typed_data';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/navigation/app_page_route.dart';
import 'media_caption_text.dart';
import '../media_attachment.dart';
import '../media_repository.dart' show MediaGoneException;
import 'file_type_visuals.dart';
import 'media_gallery_screen.dart';
import 'media_message_view.dart'
    show decryptedMediaProvider, kCaptionedMediaRadius, kStandaloneMediaRadius;
import 'video_message_player.dart' show videoThumbnailProvider;

/// WhatsApp-style mosaic preview for a multi-item media album (#109): 2 tiles
/// side-by-side, 3 as one tall + two stacked, 4+ as a 2×2 grid with a `+N`
/// overlay on the last tile. Tapping any tile opens [MediaGalleryScreen] at that
/// item. A single-item album never reaches here (it renders via
/// `MediaMessageView`).
class MediaAlbumView extends StatelessWidget {
  final MediaAlbum album;

  /// Whether the current user sent this album — drives the caption bubble color
  /// so a captioned album reads as an outgoing/incoming message (#27).
  final bool isOwn;

  /// Total mosaic width; tiles are laid out inside this.
  static const double _w = 240;
  static const double _gap = 2;

  /// Mention highlighting for the caption — see [MediaMessageView].
  final Set<String> mentionUsernames;
  final Set<String> selfMentionTokens;

  const MediaAlbumView({
    super.key,
    required this.album,
    this.isOwn = false,
    this.mentionUsernames = const {},
    this.selfMentionTokens = const {},
  });

  @override
  Widget build(BuildContext context) {
    final caption = album.caption;
    final hasCaption = caption != null && caption.isNotEmpty;
    // Captioned mosaic nests concentrically in the tint bubble (top 15, bottom
    // 6); standalone mosaic is uniformly rounded.
    final mosaic = ClipRRect(
      borderRadius: hasCaption ? kCaptionedMediaRadius : kStandaloneMediaRadius,
      child: SizedBox(width: _w, child: _mosaic(context)),
    );
    if (!hasCaption) return mosaic;
    // Mosaic + caption wrapped in one tinted bubble in the sender's color (#27).
    final scheme = Theme.of(context).colorScheme;
    final bubbleColor =
        isOwn ? scheme.primaryContainer : scheme.surfaceContainerHigh;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: bubbleColor,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          mosaic,
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 5, 6, 3),
            // Wrap the caption to the mosaic width (−12 for its own inset) so the
            // bubble hugs the mosaic — no blue border to the right (Gerry
            // 2026-07-23).
            child: SizedBox(
              width: _w - 12,
              child: _caption(context, caption),
            ),
          ),
        ],
      ),
    );
  }

  Widget _caption(BuildContext context, String caption) => MediaCaptionText(
    caption: caption,
    isOwn: isOwn,
    mentionUsernames: mentionUsernames,
    selfMentionTokens: selfMentionTokens,
  );

  Widget _mosaic(BuildContext context) {
    final items = album.items;
    final n = items.length;
    const half = (_w - _gap) / 2;

    if (n == 2) {
      return SizedBox(
        height: half,
        child: Row(children: [
          _tile(context, 0, half, half),
          const SizedBox(width: _gap),
          _tile(context, 1, half, half),
        ]),
      );
    }
    if (n == 3) {
      const h = _w * 0.66;
      return SizedBox(
        height: h,
        child: Row(children: [
          _tile(context, 0, half, h),
          const SizedBox(width: _gap),
          Column(children: [
            _tile(context, 1, half, (h - _gap) / 2),
            const SizedBox(height: _gap),
            _tile(context, 2, half, (h - _gap) / 2),
          ]),
        ]),
      );
    }
    // 4+ → 2×2, last visible tile shows +N overflow.
    final extra = n - 4;
    return SizedBox(
      height: _w,
      child: Column(children: [
        Row(children: [
          _tile(context, 0, half, half),
          const SizedBox(width: _gap),
          _tile(context, 1, half, half),
        ]),
        const SizedBox(height: _gap),
        Row(children: [
          _tile(context, 2, half, half),
          const SizedBox(width: _gap),
          _tile(context, 3, half, half, overflow: extra > 0 ? extra : null),
        ]),
      ]),
    );
  }

  Widget _tile(
    BuildContext context,
    int index,
    double width,
    double height, {
    int? overflow,
  }) {
    final item = album.items[index];
    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        appPageRoute<void>(
          builder: (_) =>
              MediaGalleryScreen(items: album.items, initialIndex: index),
        ),
      ),
      child: SizedBox(
        width: width,
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _tileContent(context, item),
            if (overflow != null)
              Container(
                color: Colors.black54,
                alignment: Alignment.center,
                child: Text(
                  '+$overflow',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _tileContent(BuildContext context, MediaAttachment item) {
    switch (item.mediaType) {
      case MediaType.image:
        return _AlbumImageTile(attachment: item);
      case MediaType.video:
        return _AlbumVideoTile(attachment: item);
      case MediaType.audio:
      case MediaType.file:
        final visual = FileTypeVisual.of(item);
        return Container(
          color: visual.color.withValues(alpha: 0.15),
          alignment: Alignment.center,
          child: Icon(visual.icon, color: visual.color, size: 32),
        );
    }
  }
}

/// One video tile: shows the sender's encrypted cover frame (#b) — decrypted
/// from the tiny `tp/tk` blob, no video download — behind a play badge. Falls
/// back to a plain black+play cell when the sender attached no cover (older/
/// non-native sender, or generation failed).
class _AlbumVideoTile extends ConsumerWidget {
  final MediaAttachment attachment;

  const _AlbumVideoTile({required this.attachment});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final thumb =
        ref.watch(videoThumbnailProvider(attachment)).asData?.value;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (thumb != null)
          Image.memory(thumb, fit: BoxFit.cover, cacheWidth: 300)
        else
          const ColoredBox(color: Colors.black),
        // Scrim + play badge, legible over any frame.
        const DecoratedBox(
          decoration: BoxDecoration(color: Colors.black26),
        ),
        const Center(
          child: Icon(Icons.play_circle_outline, color: Colors.white, size: 40),
        ),
      ],
    );
  }
}

/// One image tile: decrypts on demand, downscaled for the small mosaic cell.
class _AlbumImageTile extends ConsumerWidget {
  final MediaAttachment attachment;

  const _AlbumImageTile({required this.attachment});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(decryptedMediaProvider(attachment));
    return async.when(
      loading: () => Container(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        child: const Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
      error: (e, _) => Container(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        child: Icon(
          e is MediaGoneException
              ? Icons.hide_image_outlined
              : Icons.broken_image_outlined,
          size: 24,
          semanticLabel: e is MediaGoneException ? 'media.gone'.tr() : null,
        ),
      ),
      data: (Uint8List bytes) =>
          Image.memory(bytes, fit: BoxFit.cover, cacheWidth: 300),
    );
  }
}
