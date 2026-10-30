// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:image/image.dart' as img;

import '../../core/logging/logger_service.dart';
import 'file_chunker.dart';
import 'image_metadata.dart';
import 'media_attachment.dart';
import 'shot_text_blocks.dart';

/// The text blocks on a photo shot — **rendered into the pixels**, not placed
/// beside them.
///
/// **Why into the picture and not into the envelope.** A shot deliberately has
/// no caption: it would outlive the picture. The content burns on opening, the
/// caption would stay in the history as text, searchable, quotable, copyable —
/// and would thereby go on telling exactly what the shot is not supposed to
/// tell. A second channel for text is not a convenience at this point but a
/// leak.
///
/// So there is no second channel. The sentence becomes part of the photo before
/// it is encrypted — it burns with it because it IS it. A side effect that is
/// none here: it cannot be changed afterwards. With something one looks at
/// exactly once, there is nothing to touch up.
///
/// **No envelope field, no new version, no change at the recipient.** What
/// comes out here is an ordinary photo; the whole send path behind it notices
/// nothing.
///
/// Photos only. Captioning a video would mean re-encoding it — minutes of
/// compute for one line of text, and the sound would suffer along.
/// `easy_video_editor` can trim, shrink and rotate, but no text; a second text
/// channel in the envelope would again be precisely what is ruled out above.
///
/// **Several blocks, free in height** (1.29). Before, there was exactly one
/// bar, fixed in the middle of the picture. The position now comes from the
/// block itself — as a fraction of the image height, so that preview and result
/// compute the same number ([ShotTextBlock]).

/// Appearance of the bar. Lives here so that the preview in the send sheet and
/// what actually travels into the picture have **the same source** — otherwise
/// one types against a preview that looks different from the result.
class ShotCaptionStyle {
  /// Black, but transparent enough that one can see what lies beneath.
  static const Color background = Color(0x8C000000);

  static const Color foreground = Color(0xFFFFFFFF);

  /// Font size as a fraction of the **image width**. A fixed point value would
  /// be a crumb on a 4000-pixel photo and a wall on a 600-pixel one.
  ///
  /// Adjusted to 1/30 on the device (Gerry, 2026-08-28): at 1/24 the bar took
  /// too much away from the picture — it is meant to write something into it,
  /// not to cover it up.
  static const double fontSizeRatio = 1 / 30;

  /// …but never larger than a fourteenth of the **height**.
  ///
  /// **Why both measures are needed** (Gerry, 2026-08-28: "how does that work
  /// with different picture sizes?"). Hanging on the width is right for
  /// display: a phone in portrait shows practically every photo width-limited —
  /// the screen aspect ratio (~0.46) is narrower than any common photo — so the
  /// sentence always ends up at roughly the same fraction of the screen width
  /// for the viewer, no matter what resolution or orientation the original had.
  ///
  /// With a **very wide** picture that tips over, though: at 4:1, 1/30 of the
  /// width is already 1/7 of the height, and the bar would cover a quarter of
  /// the panorama. Hence the second limit. It is a pure function of the
  /// dimensions — no measuring of text — so that preview and burned result can
  /// compute the same number.
  static const double maxFontHeightRatio = 1 / 14;

  /// The font size for a picture of these dimensions. **The one source** for
  /// the preview in the send sheet and for what is actually painted.
  static double fontSizeFor(double width, double height) => math.min(
        width * fontSizeRatio,
        height * maxFontHeightRatio,
      );

  /// Padding of the bar, as a fraction of the font size.
  static const double paddingRatio = 0.55;

  /// More than four lines is no longer a sentence but a letter.
  static const int maxLines = 4;

  /// Maximum length. Without a limit somebody pushes in a paragraph that would
  /// be cut off at [maxLines] anyway — better to brake beforehand.
  static const int maxChars = 160;
}

/// Renders [bloecke] into the photo of [item].
///
/// Returns **[item] itself** when in doubt: without text, for anything that is
/// not an image, and when drawing fails. A few lines of text are not worth
/// aborting a send over — then the photo simply goes out without them.
Future<OutgoingMedia> burnShotTextBlocks(
  OutgoingMedia item,
  List<ShotTextBlock> blocks,
) async {
  final sichtbar = visibleTextBlocks(blocks);
  if (sichtbar.isEmpty) return item;
  if (MediaType.fromMime(item.mime) != MediaType.image) return item;

  try {
    final source = item.bytes ?? await readFileBytes(item.sourcePath!);

    // **Upright first** — the same trap as when downscaling
    // (`media_downscale.dart`): the canvas does not know the EXIF orientation,
    // and the finished drawn result carries none any more. Whoever draws first
    // pastes the sentence onto a picture the recipient then sees tipped over —
    // with the text sideways to it.
    final upright = await ImageMetadata.normalizeAndStrip(source, item.mime);

    final gezeichnet = await _zeichne(upright, sichtbar);
    if (gezeichnet == null) return item;

    final istPng = item.mime.toLowerCase() == 'image/png';
    final bytes = await compute(_kodiere, (gezeichnet, istPng));
    if (bytes == null) return item;

    return OutgoingMedia.bytes(
      bytes,
      fileName: istPng
          ? item.fileName
          : '${_withoutExtension(item.fileName)}.jpg',
      mime: istPng ? 'image/png' : 'image/jpeg',
    );
  } catch (e) {
    logger.warning('Shot-Text konnte nicht gezeichnet werden: $e',
        tag: 'Shot');
    return item;
  }
}

/// Raw pixels along with dimensions — the only thing an isolate can accept from
/// a drawn image (`ui.Image` stays where it came into being).
typedef _Canvas = (Uint8List rgba, int width, int height);

/// Draws picture + bars + text and returns the pixels.
///
/// Deliberately does NOT run in an isolate: `dart:ui` cannot paint there. The
/// expensive part — the encoding afterwards — can, and that is moved out.
Future<_Canvas?> _zeichne(
    Uint8List bytes, List<ShotTextBlock> blocks) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final image = frame.image;
  try {
    final w = image.width.toDouble();
    final h = image.height.toDouble();

    final fontSize = ShotCaptionStyle.fontSizeFor(w, h);
    final padding = fontSize * ShotCaptionStyle.paddingRatio;

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder, ui.Rect.fromLTWH(0, 0, w, h));
    canvas.drawImage(image, ui.Offset.zero, ui.Paint());

    for (final block in blocks) {
      final painter = TextPainter(
        text: TextSpan(
          text: _kuerze(block.text, ShotCaptionStyle.maxChars),
          style: TextStyle(
            color: ShotCaptionStyle.foreground,
            fontSize: fontSize,
            height: 1.25,
            // No `fontFamily`: the platform's default type. A custom one would
            // have to be bundled and loaded before anything is painted here —
            // otherwise it silently draws in a fallback face.
          ),
        ),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
        maxLines: ShotCaptionStyle.maxLines,
        ellipsis: '…',
      )..layout(maxWidth: w - 2 * padding);

      final bandHeight = painter.height + 2 * padding;
      // The same arithmetic as in the preview — which is why it lives in
      // shot_text_blocks.dart and not twice, here and there.
      final top = shotTextBlockTop(
        y: block.y,
        bandHeight: bandHeight,
        imageHeight: h,
      );

      canvas.drawRect(
        ui.Rect.fromLTWH(0, top, w, bandHeight),
        ui.Paint()..color = ShotCaptionStyle.background,
      );
      // **Centre it ourselves.** `TextAlign.center` only aligns WITHIN the
      // width the painter claims for itself after line breaking — and for a
      // short line that is the line itself, not the bar. The sentence therefore
      // stuck to the left edge while the preview showed it centred (Gerry on
      // the iPhone, 2026-08-28). Here the whole text block is pushed into the
      // bar so that both show the same thing.
      final inner = w - 2 * padding;
      final left = padding + (inner - painter.width) / 2;
      painter.paint(canvas, ui.Offset(left, top + padding));
    }

    final image2 = await recorder.endRecording().toImage(image.width, image.height);
    try {
      final daten = await image2.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (daten == null) return null;
      return (daten.buffer.asUint8List(), image.width, image.height);
    } finally {
      image2.dispose();
    }
  } finally {
    image.dispose();
  }
}

/// Runs in the isolate: raw pixels → JPEG (or PNG, so transparency survives —
/// the same rule as when downscaling).
Uint8List? _kodiere((_Canvas, bool) input) {
  final ((rgba, w, h), istPng) = input;
  try {
    final image = img.Image.fromBytes(
      width: w,
      height: h,
      bytes: rgba.buffer,
      numChannels: 4,
    );
    return istPng ? img.encodePng(image) : img.encodeJpg(image, quality: 90);
  } catch (_) {
    return null;
  }
}

/// Hard upper bound without cutting a character in half: half a surrogate pair
/// would be a box. The actual brake is the input field; this is the belt in
/// case somebody else calls.
String _kuerze(String s, int max) {
  if (s.length <= max) return s;
  var end = max;
  final last = s.codeUnitAt(end - 1);
  if (last >= 0xD800 && last <= 0xDBFF) end--;
  return s.substring(0, end);
}

String _withoutExtension(String name) {
  final i = name.lastIndexOf('.');
  return i <= 0 ? name : name.substring(0, i);
}
