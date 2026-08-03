// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute, visibleForTesting;
import 'package:image/image.dart' as img;

/// Lossless removal of metadata (EXIF/GPS/XMP/comments) from image bytes
/// **before** they are encrypted and sent (audit L6).
///
/// A camera photo carries EXIF with the exact GPS coordinates, device model,
/// and timestamps — a serious deanonymization leak for a privacy chat. We strip
/// it by rewriting the container at the segment/chunk level, WITHOUT decoding
/// or re-encoding the pixels, so image quality is untouched and no image
/// codec dependency is needed.
///
/// Handles the two formats that carry EXIF in practice on web/Android (JPEG,
/// PNG). Other formats (HEIC/WebP/GIF) are returned unchanged — a documented
/// gap; iOS captures are converted to JPEG by the pipeline where possible.
/// On any parse surprise the original bytes are returned (never corrupt an
/// image just to strip metadata).
class ImageMetadata {
  ImageMetadata._();

  /// Like [strip], but first BAKES a JPEG's EXIF orientation into the pixels
  /// when it is anything other than "upright" (tag 0x0112 ∈ 2..8).
  ///
  /// [strip] alone dropped the whole APP1 segment — including the Orientation
  /// tag — without rotating the pixels, so iOS camera photos (which store
  /// sensor-native pixels + an orientation tag) arrived sideways at every
  /// recipient. Baking decodes + re-encodes (quality 92, one-time loss) but
  /// ONLY for rotated JPEGs; upright/absent orientation keeps the lossless
  /// segment-copy fast path. The decode/encode runs in a `compute()` isolate
  /// (falls back to sync on web). On any surprise the plain [strip] result is
  /// returned — privacy still wins over rotation.
  static Future<Uint8List> normalizeAndStrip(
    Uint8List bytes,
    String mime,
  ) async {
    try {
      final m = mime.toLowerCase();
      final isJpeg =
          m == 'image/jpeg' || m == 'image/jpg' || _looksJpeg(bytes);
      if (isJpeg) {
        final orientation = jpegOrientation(bytes);
        if (orientation != null && orientation >= 2 && orientation <= 8) {
          final baked = await compute(_bakeJpegOrientation, bytes);
          // Bake drops the orientation tag; strip removes the rest of the
          // re-embedded EXIF (GPS etc.) + comments.
          if (baked != null) return _stripJpeg(baked);
        }
      }
    } catch (_) {
      // Fall through to the plain strip — never break sending.
    }
    return strip(bytes, mime);
  }

  /// Strip metadata from [bytes] if it's a supported image, else return as-is.
  static Uint8List strip(Uint8List bytes, String mime) {
    try {
      final m = mime.toLowerCase();
      if (m == 'image/jpeg' || m == 'image/jpg' || _looksJpeg(bytes)) {
        return _stripJpeg(bytes);
      }
      if (m == 'image/png' || _looksPng(bytes)) {
        return _stripPng(bytes);
      }
    } catch (_) {
      // Fall through: never break sending over a metadata strip.
    }
    return bytes;
  }

  static bool _looksJpeg(Uint8List b) =>
      b.length > 3 && b[0] == 0xFF && b[1] == 0xD8;

  static bool _looksPng(Uint8List b) =>
      b.length > 8 &&
      b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4E &&
      b[3] == 0x47;

  // ── Intrinsic dimensions ──────────────────────────────────────────────────
  /// Read an image's pixel width/height straight from its container header —
  /// NO pixel decode, no image-codec dependency — so the sender can attach them
  /// to the envelope (#9, avoids recipient scroll-flicker). Supports the formats
  /// that occur in practice (JPEG, PNG, GIF, WebP); returns null for anything
  /// else or on any parse surprise (the recipient just falls back to guessing).
  static ({int width, int height})? dimensions(Uint8List b) {
    try {
      if (_looksJpeg(b)) return _jpegSize(b);
      if (_looksPng(b)) return _pngSize(b);
      if (_looksGif(b)) return _gifSize(b);
      if (_looksWebp(b)) return _webpSize(b);
    } catch (_) {
      // Never let a size probe break sending.
    }
    return null;
  }

  static bool _looksGif(Uint8List b) =>
      b.length > 10 &&
      b[0] == 0x47 && // G
      b[1] == 0x49 && // I
      b[2] == 0x46; // F

  static bool _looksWebp(Uint8List b) =>
      b.length > 15 &&
      b[0] == 0x52 && // R
      b[1] == 0x49 && // I
      b[2] == 0x46 && // F
      b[3] == 0x46 && // F
      b[8] == 0x57 && // W
      b[9] == 0x45 && // E
      b[10] == 0x42 && // B
      b[11] == 0x50; // P

  static ({int width, int height})? _jpegSize(Uint8List b) {
    var i = 2; // past SOI
    while (i + 1 < b.length) {
      if (b[i] != 0xFF) return null;
      final marker = b[i + 1];
      // Standalone markers (no length payload).
      if (marker == 0xD8 || marker == 0xD9 || marker == 0x01 ||
          (marker >= 0xD0 && marker <= 0xD7)) {
        i += 2;
        continue;
      }
      if (i + 3 >= b.length) return null;
      final len = (b[i + 2] << 8) | b[i + 3];
      // SOF0..SOF15 carry the frame size — but not the DHT/DAC/etc. in that
      // range (C4/C8/CC), which aren't start-of-frame markers.
      final isSof = marker >= 0xC0 &&
          marker <= 0xCF &&
          marker != 0xC4 &&
          marker != 0xC8 &&
          marker != 0xCC;
      if (isSof) {
        if (i + 9 >= b.length) return null;
        final height = (b[i + 5] << 8) | b[i + 6];
        final width = (b[i + 7] << 8) | b[i + 8];
        return (width: width, height: height);
      }
      if (len < 2) return null;
      i += 2 + len;
    }
    return null;
  }

  static ({int width, int height})? _pngSize(Uint8List b) {
    // IHDR is the first chunk: sig(8) len(4) 'IHDR'(4) width(4) height(4)...
    if (b.length < 24) return null;
    final width =
        (b[16] << 24) | (b[17] << 16) | (b[18] << 8) | b[19];
    final height =
        (b[20] << 24) | (b[21] << 16) | (b[22] << 8) | b[23];
    return (width: width, height: height);
  }

  static ({int width, int height})? _gifSize(Uint8List b) {
    // Logical Screen Descriptor: header(6) then width(2 LE) height(2 LE).
    if (b.length < 10) return null;
    final width = b[6] | (b[7] << 8);
    final height = b[8] | (b[9] << 8);
    return (width: width, height: height);
  }

  static ({int width, int height})? _webpSize(Uint8List b) {
    // RIFF(4) size(4) 'WEBP'(4) then a chunk FourCC at offset 12.
    if (b.length < 30) return null;
    final fourcc = String.fromCharCodes(b, 12, 16);
    if (fourcc == 'VP8 ') {
      // Lossy: after the 10-byte frame tag, a 3-byte start code, then 16-bit LE
      // width/height (14 significant bits each) at offsets 26/28.
      final width = (b[26] | (b[27] << 8)) & 0x3FFF;
      final height = (b[28] | (b[29] << 8)) & 0x3FFF;
      return (width: width, height: height);
    }
    if (fourcc == 'VP8L') {
      // Lossless: signature byte 0x2F at offset 20, then 14-bit width-1 and
      // height-1 packed little-endian across offsets 21..24.
      if (b[20] != 0x2F) return null;
      final bits = b[21] | (b[22] << 8) | (b[23] << 16) | (b[24] << 24);
      final width = (bits & 0x3FFF) + 1;
      final height = ((bits >> 14) & 0x3FFF) + 1;
      return (width: width, height: height);
    }
    if (fourcc == 'VP8X') {
      // Extended: 1-byte flags + 3 reserved, then 24-bit LE width-1/height-1.
      final width = (b[24] | (b[25] << 8) | (b[26] << 16)) + 1;
      final height = (b[27] | (b[28] << 8) | (b[29] << 16)) + 1;
      return (width: width, height: height);
    }
    return null;
  }

  // ── EXIF orientation ─────────────────────────────────────────────────────

  /// Reads the EXIF Orientation (tag 0x0112, values 1..8) from a JPEG's APP1
  /// segment, or null when absent/unparseable. Pure header walk — no decode.
  @visibleForTesting
  static int? jpegOrientation(Uint8List b) {
    try {
      if (!_looksJpeg(b)) return null;
      var i = 2;
      while (i + 3 < b.length) {
        if (b[i] != 0xFF) return null;
        final marker = b[i + 1];
        if (marker == 0xD9 || marker == 0xDA) return null; // EOI / scan
        if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
          i += 2;
          continue;
        }
        final len = (b[i + 2] << 8) | b[i + 3];
        if (len < 2 || i + 2 + len > b.length) return null;
        if (marker == 0xE1) {
          final o = _exifOrientation(b, i + 4, i + 2 + len);
          if (o != null) return o;
        }
        i += 2 + len;
      }
    } catch (_) {
      // Treat any parse surprise as "no orientation".
    }
    return null;
  }

  /// Parses the TIFF structure inside an APP1 payload ([start], [end)) for
  /// IFD0's Orientation SHORT.
  static int? _exifOrientation(Uint8List b, int start, int end) {
    // "Exif\0\0" preamble.
    if (end - start < 14) return null;
    if (b[start] != 0x45 || b[start + 1] != 0x78 ||
        b[start + 2] != 0x69 || b[start + 3] != 0x66 ||
        b[start + 4] != 0 || b[start + 5] != 0) {
      return null;
    }
    final t = start + 6; // TIFF header origin
    final bool little;
    if (b[t] == 0x49 && b[t + 1] == 0x49) {
      little = true;
    } else if (b[t] == 0x4D && b[t + 1] == 0x4D) {
      little = false;
    } else {
      return null;
    }
    int u16(int off) => little
        ? b[off] | (b[off + 1] << 8)
        : (b[off] << 8) | b[off + 1];
    int u32(int off) => little
        ? b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24)
        : (b[off] << 24) | (b[off + 1] << 16) | (b[off + 2] << 8) | b[off + 3];
    if (u16(t + 2) != 42) return null;
    final ifd = t + u32(t + 4);
    if (ifd + 2 > end) return null;
    final count = u16(ifd);
    for (var e = 0; e < count; e++) {
      final entry = ifd + 2 + e * 12;
      if (entry + 12 > end) return null;
      if (u16(entry) == 0x0112) {
        // Type SHORT (3), count 1 — the value sits in the first two bytes of
        // the inline value field.
        final v = u16(entry + 8);
        return (v >= 1 && v <= 8) ? v : null;
      }
    }
    return null;
  }

  // ── JPEG ────────────────────────────────────────────────────────────────
  // Layout: SOI(FFD8), then marker segments [FF, marker, len(2, big-endian,
  // includes the 2 length bytes), data...], until SOS(FFDA) after which the
  // entropy-coded scan runs to EOI. We drop APP1 (EXIF + XMP) and COM
  // (comments); everything structural (JFIF APP0, ICC APP2, quant/huffman
  // tables, frame headers, scan data) is copied verbatim.

  static Uint8List _stripJpeg(Uint8List b) {
    if (!_looksJpeg(b)) return b;
    final out = BytesBuilder();
    out.add([0xFF, 0xD8]); // SOI
    var i = 2;
    while (i + 1 < b.length) {
      if (b[i] != 0xFF) {
        // Not at a marker — structure we don't understand; bail out safely.
        return b;
      }
      final marker = b[i + 1];
      // Standalone markers without a length (RSTn, EOI, TEM): copy + continue.
      if (marker == 0xD9) {
        // EOI
        out.add([0xFF, 0xD9]);
        return out.toBytes();
      }
      if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
        out.add([0xFF, marker]);
        i += 2;
        continue;
      }
      if (i + 3 >= b.length) return b;
      final len = (b[i + 2] << 8) | b[i + 3]; // includes the 2 length bytes
      if (len < 2 || i + 2 + len > b.length) return b;
      final segStart = i;
      final segEnd = i + 2 + len;

      final isApp1 = marker == 0xE1; // EXIF / XMP
      final isComment = marker == 0xFE; // COM
      if (!isApp1 && !isComment) {
        out.add(Uint8List.sublistView(b, segStart, segEnd));
      }

      if (marker == 0xDA) {
        // SOS: the entropy-coded scan follows — copy the rest verbatim.
        out.add(Uint8List.sublistView(b, segEnd, b.length));
        return out.toBytes();
      }
      i = segEnd;
    }
    return out.toBytes();
  }

  // ── PNG ─────────────────────────────────────────────────────────────────
  // Layout: 8-byte signature, then chunks [len(4), type(4), data, crc(4)].
  // We drop the metadata chunks (text + timestamp + EXIF); everything else
  // (IHDR, PLTE, IDAT, IEND, color chunks like gAMA/sRGB/iCCP) is kept, so
  // no CRCs need recomputing.

  static const Set<String> _pngDropChunks = {
    'tEXt', 'zTXt', 'iTXt', // text (can hold arbitrary metadata)
    'eXIf', // EXIF (incl. GPS)
    'tIME', // last-modification time
  };

  // ── PNG strip ───────────────────────────────────────────────────────────

  static Uint8List _stripPng(Uint8List b) {
    if (!_looksPng(b)) return b;
    final out = BytesBuilder();
    out.add(Uint8List.sublistView(b, 0, 8)); // signature
    var i = 8;
    while (i + 8 <= b.length) {
      final len = (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];
      if (len < 0 || i + 12 + len > b.length) return b;
      final type = String.fromCharCodes(b, i + 4, i + 8);
      final chunkEnd = i + 12 + len; // len(4)+type(4)+data(len)+crc(4)
      if (!_pngDropChunks.contains(type)) {
        out.add(Uint8List.sublistView(b, i, chunkEnd));
      }
      if (type == 'IEND') break;
      i = chunkEnd;
    }
    return out.toBytes();
  }
}

/// `compute()` entry point: decode a JPEG, bake its EXIF orientation into the
/// pixels, re-encode (quality 92). Returns null when the decode fails (the
/// caller then falls back to the lossless strip).
Uint8List? _bakeJpegOrientation(Uint8List bytes) {
  final decoded = img.decodeJpg(bytes);
  if (decoded == null) return null;
  final baked = img.bakeOrientation(decoded);
  return Uint8List.fromList(img.encodeJpg(baked, quality: 92));
}
