// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import 'image_metadata.dart';

/// Formats an avatar may be stored in, mapped to the file extension we give
/// the object. Deliberately narrow: an avatar is shown on every platform we
/// support — phones, desktops and plain browsers — so it must be a format all
/// of them can decode. HEIC is the one that broke this in practice.
const Map<String, String> kAvatarMimeExtensions = {
  'image/jpeg': 'jpg',
  'image/png': 'png',
  'image/webp': 'webp',
  'image/gif': 'gif',
};

/// Longest edge an avatar needs. It is drawn at ~40–120 logical pixels; 1024
/// leaves room for the full-screen viewer and still keeps the object small.
const int kAvatarMaxEdge = 1024;

/// Above this we re-encode rather than store what we were handed. One avatar
/// in production was 3.1 MB — fetched again by every viewer, forever.
const int kAvatarMaxBytes = 512 * 1024;

/// An image that is ready to be stored: bytes, the format they really are,
/// and the matching extension.
@immutable
class PickedAvatar {
  const PickedAvatar({
    required this.bytes,
    required this.mime,
    required this.extension,
  });

  final Uint8List bytes;
  final String mime;
  final String extension;
}

/// The picked file is not a format we can store.
///
/// Carries [sniffed] (a MIME string, or null when unrecognisable) so the UI
/// can say what was wrong instead of "error".
class UnsupportedAvatarFormat implements Exception {
  const UnsupportedAvatarFormat(this.sniffed);

  final String? sniffed;

  bool get isHeif => sniffed == 'image/heic';

  @override
  String toString() => 'UnsupportedAvatarFormat($sniffed)';
}

/// Let the user choose a picture for an avatar and return storable bytes.
///
/// On phones this goes through `image_picker` with a size and quality bound,
/// which makes the platform hand back **JPEG** — the only reliable way to
/// accept an iPhone photo, since those are HEIC and neither Dart nor a browser
/// can decode them. Everywhere else `FilePicker` stays (there is no photo
/// library to speak of), and the bytes are checked and, if needed, re-encoded
/// here.
///
/// Returns null when the user cancels. Throws [UnsupportedAvatarFormat] for a
/// file we will not store.
Future<PickedAvatar?> pickAvatarImage() async {
  final Uint8List? raw = await _pickBytes();
  if (raw == null) return null;
  return prepareAvatarBytes(raw);
}

/// Take a photo and return storable bytes — same bounds as [pickAvatarImage].
Future<PickedAvatar?> captureAvatarImage() async {
  final shot = await ImagePicker().pickImage(
    source: ImageSource.camera,
    maxWidth: kAvatarMaxEdge.toDouble(),
    maxHeight: kAvatarMaxEdge.toDouble(),
    imageQuality: 85,
  );
  if (shot == null) return null;
  return prepareAvatarBytes(await shot.readAsBytes());
}

Future<Uint8List?> _pickBytes() async {
  if (!kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android)) {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      // Both bounds AND a quality force a re-encode, so what comes back is
      // JPEG even when the library holds HEIC.
      maxWidth: kAvatarMaxEdge.toDouble(),
      maxHeight: kAvatarMaxEdge.toDouble(),
      imageQuality: 85,
    );
    return picked == null ? null : await picked.readAsBytes();
  }

  final result = await FilePicker.pickFiles(
    type: FileType.image,
    withData: true,
  );
  return result?.files.firstOrNull?.bytes;
}

/// Validate and, where necessary, shrink [bytes] into something we are willing
/// to store. Pure enough to test: no picker, no network.
///
/// Throws [UnsupportedAvatarFormat] when the magic number is not one of
/// [kAvatarMimeExtensions] — including HEIC, which the picker on a phone will
/// already have converted, but which can still arrive through the file picker
/// on a desktop.
@visibleForTesting
Future<PickedAvatar> prepareAvatarBytes(Uint8List bytes) async {
  final mime = ImageMetadata.sniffMime(bytes);
  if (mime == null || !kAvatarMimeExtensions.containsKey(mime)) {
    throw UnsupportedAvatarFormat(mime);
  }

  final small = await _shrinkIfNeeded(bytes, mime);
  // Re-sniff: shrinking may have changed the container (WebP in → JPEG out).
  final finalMime = ImageMetadata.sniffMime(small) ?? mime;
  return PickedAvatar(
    bytes: small,
    mime: finalMime,
    extension: kAvatarMimeExtensions[finalMime]!,
  );
}

Future<Uint8List> _shrinkIfNeeded(Uint8List bytes, String mime) async {
  if (bytes.length <= kAvatarMaxBytes) return bytes;
  // An animated GIF would lose its animation on a decode/encode round trip,
  // and package:image only ever hands us the first frame. Better a large GIF
  // than a still one presented as if it moved.
  if (mime == 'image/gif') return bytes;

  try {
    final resized = await compute(_resizeSync, (bytes, mime));
    // Only take the new bytes if they actually are smaller — a re-encode can
    // grow a well-compressed source.
    return resized != null && resized.length < bytes.length ? resized : bytes;
  } catch (_) {
    // Storing a big picture beats refusing a valid one.
    return bytes;
  }
}

/// Runs in an isolate: decode, bound the longest edge, re-encode.
///
/// PNG stays PNG so transparency survives (an avatar with a cut-out background
/// would otherwise get a black one); everything else becomes JPEG.
Uint8List? _resizeSync((Uint8List, String) input) {
  final (bytes, mime) = input;
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;

  final longest = decoded.width > decoded.height ? decoded.width : decoded.height;
  final resized = longest > kAvatarMaxEdge
      ? img.copyResize(
          decoded,
          width: decoded.width >= decoded.height ? kAvatarMaxEdge : null,
          height: decoded.height > decoded.width ? kAvatarMaxEdge : null,
          interpolation: img.Interpolation.average,
        )
      : decoded;

  return mime == 'image/png'
      ? img.encodePng(resized)
      : img.encodeJpg(resized, quality: 85);
}
