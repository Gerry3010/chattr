// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter/painting.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../core/logging/logger_service.dart';
import '../identity/identity_color.dart';

/// Puts an avatar on disk so the OS can show it in the share-sheet suggestion
/// row.
///
/// **Why this exists.** Both native donation paths want a FILE — iOS builds an
/// `INImage` from one, Android an adaptive icon. Chattr avatars are plain
/// network URLs rendered through `NetworkImage`, which caches in memory only, so
/// there was never a path to hand over. `ShareRecipient.avatarPath` was
/// therefore always null and every suggestion showed a blank circle next to
/// WhatsApp's photo (seen 2026-08-05).
///
/// **What it must not do.** A donation happens on EVERY send. Downloading an
/// avatar each time would hang a network round-trip off the send path, so a hit
/// is a single `File.exists` and nothing else. Misses download once per URL and
/// are then permanent for that URL — avatar changes carry a fresh path (and the
/// group URL a cache-busting query), so a new picture is simply a new key.
///
/// **Everything here is best-effort.** No network, no permission, a corrupt
/// response, an unwritable cache — all end in `null`, which is exactly the state
/// the feature had before. The suggestion still works, it just has no picture.
class ShareSuggestionAvatarCache {
  const ShareSuggestionAvatarCache._();

  /// Subdirectory under the app cache. Its own folder so [clear] can drop
  /// everything without touching another feature's files.
  static const String _dirName = 'share_suggestion_avatars';

  /// Cap on a downloaded avatar. Avatars are small; anything larger is either
  /// not an avatar or not worth putting on the send path — and the bound on
  /// what a hostile URL could make us write.
  static const int _maxBytes = 2 * 1024 * 1024;

  /// In-memory memo of URL → path (or null for "we tried and it failed"), so a
  /// chat sent to repeatedly does not even stat the file system again.
  static final Map<String, String?> _memo = <String, String?>{};

  /// Test seam for the one thing a unit test cannot supply: the network.
  /// Null in every real build, so production always uses [http.get].
  @visibleForTesting
  static http.Client? debugClient;

  /// Local file for [url], downloading it once. Null when there is no URL, the
  /// platform has no file system, or anything at all goes wrong.
  ///
  /// [identity] is what the cache is keyed on, and it must NOT be the URL once
  /// avatars are served through signed URLs (00075): every refreshed signature
  /// would look like a different picture, so the same avatar would be
  /// downloaded again on every send and its files would pile up. Pass the
  /// storage path (`bucket/uid/avatar.jpg`); defaults to the URL for callers
  /// whose URLs are stable.
  static Future<String?> pathFor(String? url, {String? identity}) async {
    if (kIsWeb || url == null || url.isEmpty) return null;
    final key = identity ?? url;
    if (_memo.containsKey(key)) return _memo[key];
    final path = await _resolve(url, key);
    _memo[key] = path;
    return path;
  }

  /// Edge length of a rendered initials circle. The suggestion row shows it at
  /// roughly 40–60 pt; 256 keeps it crisp on a 3× screen without making the
  /// file worth thinking about (~4 kB).
  static const int _initialsSize = 256;

  /// A local PNG showing the initials circle for a contact or group that has no
  /// picture.
  ///
  /// **Why a rendered file and not a native drawing.** The OS renders the
  /// suggestion row from a file, so something has to produce pixels. Drawing it
  /// natively would mean reimplementing the colour seed AND the contrast rule —
  /// and the contrast rule is not obvious: the black/white crossover sits at
  /// relative luminance ≈0.179, not 0.5, which is a mistake we already made
  /// once (fork patch p21). Two implementations of that would drift, and the
  /// drift would be silent: a slightly-too-pale letter is not a crash. So the
  /// rule stays in [IdentityColor] and only its output travels.
  ///
  /// The caller passes the FINISHED [background] rather than a seed, so the
  /// colour is resolved exactly once — by the same call the on-screen circle
  /// uses. Handing over a seed would mean re-deriving it here, and a second
  /// derivation is a second chance to disagree.
  ///
  /// Best-effort like everything else here: any failure yields null and the
  /// suggestion simply has no picture, exactly as before.
  static Future<String?> pathForInitials({
    required Color background,
    required String displayName,
  }) async {
    if (kIsWeb) return null;
    final initials = initialsFor(displayName);
    // The key covers colour AND initials: a rename or a new identity key must
    // produce a new file, or the row would keep the old circle forever.
    final key = 'initials:${background.toARGB32()}:$initials:$_initialsSize';
    if (_memo.containsKey(key)) return _memo[key];
    final path = await _renderInitials(key, background, initials);
    _memo[key] = path;
    return path;
  }

  static Future<String?> _renderInitials(
    String key,
    Color background,
    String initials,
  ) async {
    try {
      final dir = Directory(
        '${(await getApplicationCacheDirectory()).path}/$_dirName',
      );
      final file = File(
        '${dir.path}/${sha256.convert(utf8.encode(key)).toString()}.png',
      );
      if (file.existsSync()) return file.path;

      final size = _initialsSize.toDouble();
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);

      // A full-bleed circle: iOS and Android both clip the image to a circle
      // themselves, so a square with a disc in it would show corner artefacts
      // on one of them. Filling the whole square is what survives both.
      canvas.drawRect(
        Rect.fromLTWH(0, 0, size, size),
        Paint()..color = background,
      );

      final style = IdentityColor.initialsTextStyle(size / 2, background);
      final painter = TextPainter(
        text: TextSpan(text: initials, style: style),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
      )..layout();
      painter.paint(
        canvas,
        Offset((size - painter.width) / 2, (size - painter.height) / 2),
      );

      final image = await recorder.endRecording().toImage(
            _initialsSize,
            _initialsSize,
          );
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) return null;

      await dir.create(recursive: true);
      // Same write-then-rename as the download path: a half-written PNG would
      // be treated as a cache hit forever.
      final tmp = File('${file.path}.part');
      await tmp.writeAsBytes(data.buffer.asUint8List(), flush: true);
      await tmp.rename(file.path);
      return file.path;
    } catch (e) {
      logger.warning(
        'Share-suggestion initials avatar not rendered: $e',
        tag: 'ShareSuggestions',
      );
      return null;
    }
  }

  static Future<String?> _resolve(String url, String identity) async {
    try {
      final dir = Directory(
        '${(await getApplicationCacheDirectory()).path}/$_dirName',
      );
      // The file name is a hash of the identity, never a piece of it: it
      // contains the uploader's user id, and a cache file name is the kind of
      // thing that ends up in a crash log.
      //
      // The `square:` prefix is a cache generation, not decoration. Before this
      // the raw download was stored under the bare URL hash; an installed app
      // would otherwise keep serving that stretched file forever, because a hit
      // is a `File.exists` and nothing looks inside. Changing the key retires
      // the old ones instead. They stay behind until [clear] or the OS reclaims
      // the cache directory — a few kB, and nothing reads them again.
      final file = File(
        '${dir.path}/${sha256.convert(utf8.encode('square:$identity')).toString()}'
        '.png',
      );
      if (file.existsSync()) return file.path;

      final client = debugClient;
      final res = await (client == null
              ? http.get(Uri.parse(url))
              : client.get(Uri.parse(url)))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      final bytes = res.bodyBytes;
      if (bytes.isEmpty || bytes.length > _maxBytes) return null;

      // Not the raw download: iOS and Android both clip this file into a CIRCLE
      // and neither preserves the aspect ratio while doing it, so a portrait
      // photo arrived squashed (reported 2026-08-08 — a 286×451 avatar came out
      // wide and squat in the iOS suggestion bubble). Cropping here is also the
      // only place that keeps the two paths honest: [_renderInitials] has always
      // drawn a square, which is exactly why picture-less contacts looked right
      // while everyone with a photo did not.
      final square = await _squareCrop(bytes);
      if (square == null) return null;

      await dir.create(recursive: true);
      // Write beside the target and rename, so a download interrupted halfway
      // can never leave a truncated file that we would then treat as a hit
      // forever (rename is atomic on the same filesystem).
      final tmp = File('${file.path}.part');
      await tmp.writeAsBytes(square, flush: true);
      await tmp.rename(file.path);
      return file.path;
    } catch (e) {
      logger.warning(
        'Share-suggestion avatar not cached: $e',
        tag: 'ShareSuggestions',
      );
      return null;
    }
  }

  /// Centre-cropped square PNG of [bytes], or null if it does not decode.
  ///
  /// The crop is the shorter side taken from the middle — `BoxFit.cover`, the
  /// same rule the in-app circle follows, so the face the OS shows is the face
  /// the app shows. Anything else would put the suggestion row and the chat list
  /// on different pictures of the same person.
  ///
  /// Never upscales: a small avatar stays its own size rather than being blown
  /// up to [_initialsSize] and looking softer than it needs to.
  static Future<Uint8List?> _squareCrop(Uint8List bytes) async {
    ui.Image? source;
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      source = (await codec.getNextFrame()).image;
      codec.dispose();

      final w = source.width;
      final h = source.height;
      if (w <= 0 || h <= 0) return null;
      final side = w < h ? w : h;
      final edge = side < _initialsSize ? side : _initialsSize;

      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawImageRect(
        source,
        Rect.fromLTWH(
          (w - side) / 2,
          (h - side) / 2,
          side.toDouble(),
          side.toDouble(),
        ),
        Rect.fromLTWH(0, 0, edge.toDouble(), edge.toDouble()),
        Paint()..filterQuality = FilterQuality.medium,
      );
      final picture = recorder.endRecording();
      final cropped = await picture.toImage(edge, edge);
      picture.dispose();
      final data = await cropped.toByteData(format: ui.ImageByteFormat.png);
      cropped.dispose();
      return data?.buffer.asUint8List();
    } catch (e) {
      // An avatar we cannot decode is one the OS could not have drawn either,
      // so this degrades to the initials circle rather than to a broken tile.
      logger.warning(
        'Share-suggestion avatar not decodable: $e',
        tag: 'ShareSuggestions',
      );
      return null;
    } finally {
      source?.dispose();
    }
  }

  /// Drop every cached avatar. Called alongside `deleteAll()` — once the
  /// donations are gone, keeping the pictures that fed them would leave exactly
  /// the trace the deletion was meant to remove.
  static Future<void> clear() async {
    _memo.clear();
    if (kIsWeb) return;
    try {
      final dir = Directory(
        '${(await getApplicationCacheDirectory()).path}/$_dirName',
      );
      if (dir.existsSync()) await dir.delete(recursive: true);
    } catch (e) {
      logger.warning(
        'Share-suggestion avatar cache not cleared: $e',
        tag: 'ShareSuggestions',
      );
    }
  }

  /// Test seam: forget the in-memory memo without touching disk.
  static void debugResetMemo() => _memo.clear();
}
