// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:typed_data';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/logger_service.dart';
import '../../../core/security/security_providers.dart';
import 'media_caption_text.dart';
import '../media_attachment.dart';
import '../media_compression.dart';
import '../media_repository.dart';
import 'audio_message_player.dart';
import 'file_type_visuals.dart';
import 'fullscreen_image_viewer.dart';
import 'media_action_button.dart';
import 'video_message_player.dart';
import '../image_guard.dart';

/// How often a failed media load is tried again. Never for a blob that is
/// gone for good: the default policy retried ~10 times over ~40 s, showing
/// the spinner throughout, and started over on every rebuild, so a reaped
/// photo looked like one that loads forever.
Duration? mediaRetry(int retryCount, Object error) {
  if (error is MediaGoneException || retryCount >= 4) return null;
  return Duration(milliseconds: 300 * (1 << retryCount));
}

/// Downloads + decrypts a media attachment's bytes (cached per attachment).
final decryptedMediaProvider = FutureProvider.autoDispose
    .family<Uint8List, MediaAttachment>(retry: mediaRetry, (ref, att) async {
      final repo = ref.read(mediaRepositoryProvider);
      final svc = ref.read(messageEncryptionServiceProvider);
      final blob = await repo.downloadEncrypted(att.path);
      var bytes = await svc.decryptBytes(blob, base64Decode(att.keyB64));
      if (att.compression == MediaCompression.gzip) {
        bytes = await MediaCompression.decompress(
          bytes,
          maxBytes: MediaRepository.maxUploadBytes,
        );
      }
      logger.info(
        '📎 Decrypted ${att.mediaType.name} ${att.name} (${bytes.length} bytes)',
        tag: 'MediaMessageView',
      );
      // Media-retention signal (00056): tell the server this recipient now has the
      // blob, so it can be reaped once EVERYONE has it — decoupled from read
      // receipts. Fire-and-forget + idempotent; failures are harmless.
      signalMediaDownloaded(repo, att);
      return bytes;
    });

/// Corner radius of a media preview that stands ALONE (its own chat bubble):
/// uniformly rounded.
const BorderRadius kStandaloneMediaRadius = BorderRadius.all(
  Radius.circular(12),
);

/// Corner radius of a media preview rendered INSIDE a caption bubble (#27).
/// The bubble is radius 18 with 3 px padding, so the media's TOP corners nest
/// concentrically under it (18 − 3 = 15) instead of showing a tighter
/// corner-in-corner edge; its BOTTOM corners stay tight (6) because the caption
/// sits directly below — a large bottom radius would leave a rounded tint notch
/// between the media and the text. Keeps the bubble itself untouched, only the
/// content curvature is tuned to fit it.
const BorderRadius kCaptionedMediaRadius = BorderRadius.only(
  topLeft: Radius.circular(15),
  topRight: Radius.circular(15),
  bottomLeft: Radius.circular(6),
  bottomRight: Radius.circular(6),
);

/// Renders a single encrypted media attachment inside a chat bubble. Images show
/// inline; other types show a card you can open/share (decrypted on demand). A
/// non-empty album [caption] (#110) makes the media + caption read as ONE chat
/// bubble tinted in the sender's bubble color (#27: own → primaryContainer,
/// incoming → surfaceContainerHigh), the caption text in the matching on-color.
/// (Only used for a single-item album; multi-item albums render via
/// `MediaAlbumView`.)
class MediaMessageView extends ConsumerWidget {
  final MediaAttachment attachment;
  final String? caption;

  /// Whether the current user sent this message — drives the bubble color so a
  /// captioned media reads as an outgoing/incoming bubble (#27).
  final bool isOwn;

  /// Fill the parent instead of the inline box — the fullscreen gallery uses it
  /// so a video letterboxes to the whole page (forwarded to the video player).
  final bool expand;

  /// Member usernames whose `@username` runs get the mention highlight in the
  /// CAPTION, and the subset of those that means the reader.
  ///
  /// Captions used to render without either. The chat-list @-marker scans the
  /// decrypted message — envelope and all — so a caption saying `@bob` lit the
  /// marker in the list while the chat showed nothing to find.
  final Set<String> mentionUsernames;
  final Set<String> selfMentionTokens;

  const MediaMessageView({
    super.key,
    required this.attachment,
    this.caption,
    this.isOwn = false,
    this.expand = false,
    this.mentionUsernames = const {},
    this.selfMentionTokens = const {},
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final caption = this.caption;
    // Standalone media is its own bubble → uniform corners. Captioned media sits
    // inside the tint bubble → corners tuned to nest in it (kCaptionedMediaRadius).
    if (caption == null || caption.isEmpty) {
      return _media(context, ref, kStandaloneMediaRadius);
    }
    // Media + caption wrapped in one tinted bubble in the sender's color, so a
    // captioned photo reads as a single outgoing/incoming message (#27). The
    // media corners nest concentrically inside the bubble (kCaptionedMediaRadius).
    final scheme = Theme.of(context).colorScheme;
    final bubbleColor = isOwn
        ? scheme.primaryContainer
        : scheme.surfaceContainerHigh;
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
          // Fixed-width media fills the bubble (image covers it) so there's no
          // blue gap; the caption wraps to the same width.
          _media(context, ref, kCaptionedMediaRadius, captionW: _captionMediaW),
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 5, 6, 3),
            child: SizedBox(
              // −12 for the caption's own horizontal inset, so its box lines up
              // with the media edges.
              width: _captionMediaW - 12,
              child: _caption(context, caption),
            ),
          ),
        ],
      ),
    );
  }

  /// Caption text — see [MediaCaptionText] (shared with the album view).
  Widget _caption(BuildContext context, String caption) => MediaCaptionText(
    caption: caption,
    isOwn: isOwn,
    mentionUsernames: mentionUsernames,
    selfMentionTokens: selfMentionTokens,
  );

  /// [captionW] is non-null when this media sits inside a caption bubble: the
  /// media is pinned to that fixed width (an image COVERS a fixed-aspect box;
  /// video/file just fill the width) so the bubble is uniform and gap-free.
  Widget _media(
    BuildContext context,
    WidgetRef ref,
    BorderRadius radius, {
    double? captionW,
  }) {
    // Audio + video play inline; each handles its own download/decrypt + state.
    if (attachment.mediaType == MediaType.audio) {
      final audio = AudioMessagePlayer(attachment: attachment);
      return captionW != null ? SizedBox(width: captionW, child: audio) : audio;
    }
    if (attachment.mediaType == MediaType.video) {
      final video = VideoMessagePlayer(
        attachment: attachment,
        expand: expand,
        cornerRadius: radius,
      );
      return captionW != null ? SizedBox(width: captionW, child: video) : video;
    }
    // Non-displayable file (pdf/apk/zip/…): show the icon + extension + filename
    // card IMMEDIATELY (its metadata comes from the attachment) — no whole-file
    // decrypt just to preview, and a chunked large file has no single object to
    // load anyway. Decryption happens only on save/share (chunked-aware).
    if (attachment.mediaType != MediaType.image) {
      final card = _fileCard(context, radius);
      return captionW != null ? SizedBox(width: captionW, child: card) : card;
    }
    // Image → decrypt inline for the thumbnail.
    final coverBox = captionW != null ? _captionImageBox() : null;
    final async = ref.watch(decryptedMediaProvider(attachment));
    return async.when(
      loading: () {
        // Reserve the exact box the media will occupy so it doesn't jump on
        // load: the cover box when captioned, else the sender's intrinsic
        // dimensions (#9), else a small neutral placeholder (pre-#9 media).
        final size = coverBox ?? _reservedImageSize();
        return _frame(
          context,
          SizedBox(
            height: size?.height ?? 80,
            width: size?.width ?? 160,
            child: const Center(
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
          radius,
        );
      },
      error: (e, _) => _frame(
        context,
        Padding(
          padding: const EdgeInsets.all(12),
          child: e is MediaGoneException
              ? const MediaGoneNotice()
              : Text('media.load_error'.tr()),
        ),
        radius,
      ),
      data: (bytes) => _image(context, bytes, radius, box: coverBox),
    );
  }

  // Inline image display box: images are laid out to fit inside this max box.
  static const double _imgMaxW = 240;
  static const double _imgMaxH = 260;

  /// Captioned media uses a FIXED, comfortable content width so bubbles are
  /// uniform and the media fills the width — no blue gap beside a portrait image
  /// (Gerry 2026-07-23, fixed-width cover). The caption wraps to this width.
  static const double _captionMediaW = 270;

  /// A tall captioned image is cover-cropped to this height (the whole image is
  /// still one tap away in the fullscreen viewer); shorter images show fully.
  /// Stops a very-portrait shot from towering over the chat.
  static const double _captionImageMaxH = 340;

  /// Cover box for a captioned image: the fixed width, height from the aspect
  /// ratio but capped — so the image FILLS the width (BoxFit.cover crops only
  /// the vertical overflow of a tall shot). Legacy media without dimensions
  /// falls back to 4:3.
  Size _captionImageBox() {
    final ar = attachment.aspectRatio ?? (4 / 3);
    final h = (_captionMediaW / ar).clamp(60.0, _captionImageMaxH);
    return Size(_captionMediaW, h.toDouble());
  }

  /// The exact on-screen box an image will occupy, derived from the sender's
  /// intrinsic dimensions fitted inside [_imgMaxW]×[_imgMaxH]. Null when the
  /// dimensions are unknown (older media) — the caller uses a fallback size.
  Size? _reservedImageSize() {
    final ar = attachment.aspectRatio;
    if (ar == null) return null;
    var w = _imgMaxW;
    var h = w / ar;
    if (h > _imgMaxH) {
      h = _imgMaxH;
      w = h * ar;
    }
    return Size(w, h);
  }

  Widget _frame(BuildContext context, Widget child, BorderRadius radius) =>
      Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          borderRadius: radius,
        ),
        clipBehavior: Clip.antiAlias,
        child: child,
      );

  Widget _image(
    BuildContext context,
    Uint8List bytes,
    BorderRadius radius, {
    Size? box,
  }) {
    // [box] is the captioned fixed-width cover box; otherwise use the sender's
    // intrinsic size. Either way BoxFit.cover fills it (the cover box may crop a
    // tall shot; the intrinsic box matches the image exactly).
    final size = box ?? _reservedImageSize();
    // When we know the size, pin the image to the SAME box the loading
    // placeholder reserved → zero layout shift on load (#9). Otherwise fall
    // back to the max-box constraint (pre-#9 media, may still shift).
    final Widget imageChild = size != null
        ? SizedBox(
            width: size.width,
            height: size.height,
            child: GuardedMemoryImage(bytes, fit: BoxFit.cover),
          )
        : ConstrainedBox(
            constraints: const BoxConstraints(
              maxHeight: _imgMaxH,
              maxWidth: _imgMaxW,
            ),
            child: GuardedMemoryImage(bytes, fit: BoxFit.cover),
          );
    return Stack(
      children: [
        GestureDetector(
          onTap: () => _openFullscreen(context, bytes),
          child: ClipRRect(borderRadius: radius, child: imageChild),
        ),
        Positioned(
          top: 2,
          right: 2,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(20),
            ),
            child: MediaActionButton(
              attachment: attachment,
              bytes: bytes,
              color: Colors.white,
            ),
          ),
        ),
      ],
    );
  }

  Widget _fileCard(BuildContext context, BorderRadius radius) {
    final visual = FileTypeVisual.of(attachment);
    return _frame(
      context,
      Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Colored type badge (the lightweight document preview).
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: visual.color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(visual.icon, size: 26, color: visual.color),
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    attachment.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${visual.label} · ${_formatSize(attachment.size)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            // Decrypts on demand (chunked-aware) — the card itself needs no
            // bytes, so a large/undecryptable file still shows + shares.
            MediaFileActionButton(attachment: attachment),
          ],
        ),
      ),
      radius,
    );
  }

  void _openFullscreen(BuildContext context, Uint8List bytes) {
    openFullscreenImage(context, attachment: attachment, bytes: bytes);
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// The photo or video is gone for good: the server reaped it (00056) and this
/// device kept no copy (only devices from before 2026-10-15 lack one). Says
/// so, instead of a spinner waiting for something that will not come.
class MediaGoneNotice extends StatelessWidget {
  const MediaGoneNotice({super.key});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.hide_image_outlined, size: 20, color: color),
        const SizedBox(width: 8),
        Flexible(
          child: Text('media.gone'.tr(), style: TextStyle(color: color)),
        ),
      ],
    );
  }
}
