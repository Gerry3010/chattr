// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Pictures above this many pixels are not decoded at all (CHAT-39, C5).
///
/// A picture is small to send and large to open: a PNG of 50 000 × 50 000
/// fills a few KB and asks for 10 GB of memory once decoded. The bytes come
/// from whoever sent them, and a bubble decodes as soon as it scrolls into
/// view. 50 megapixels is above any phone camera in use and far below what
/// takes a device down.
const int maxImagePixels = 50 * 1000 * 1000;

/// Width and height from the file header only (no pixels decoded), or null
/// if the header is not readable.
Future<Size?> encodedImageSize(Uint8List bytes) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    return Size(descriptor.width.toDouble(), descriptor.height.toDouble());
  } catch (_) {
    return null;
  } finally {
    descriptor?.dispose();
    buffer?.dispose();
  }
}

/// Whether [bytes] may be decoded. Unreadable headers pass: the decoder then
/// fails on its own, as it always did, and nothing big was allocated.
Future<bool> imageSafeToDecode(Uint8List bytes) async {
  final size = await encodedImageSize(bytes);
  if (size == null) return true;
  return size.width * size.height <= maxImagePixels;
}

final Expando<Future<bool>> _checked = Expando<Future<bool>>();

/// [imageSafeToDecode], once per byte buffer. For widgets that build a
/// FutureBuilder in `build`: the same future keeps its result across
/// rebuilds instead of flashing back to "loading".
Future<bool> imageSafeToDecodeOnce(Uint8List bytes) =>
    _checked[bytes] ??= imageSafeToDecode(bytes);

/// [Image.memory] behind the header check, decoded no larger than
/// [maxDimension] on its longer side.
class GuardedMemoryImage extends StatefulWidget {
  const GuardedMemoryImage(
    this.bytes, {
    super.key,
    this.fit,
    this.maxDimension = 2048,
  });

  final Uint8List bytes;
  final BoxFit? fit;
  final int maxDimension;

  /// The provider the widget shows, for viewers that take an [ImageProvider].
  static ImageProvider provider(Uint8List bytes, {int maxDimension = 4096}) =>
      ResizeImage(
        MemoryImage(bytes),
        width: maxDimension,
        height: maxDimension,
        policy: ResizeImagePolicy.fit,
        allowUpscaling: false,
      );

  @override
  State<GuardedMemoryImage> createState() => _GuardedMemoryImageState();
}

class _GuardedMemoryImageState extends State<GuardedMemoryImage> {
  late Future<bool> _safe = imageSafeToDecodeOnce(widget.bytes);

  @override
  void didUpdateWidget(GuardedMemoryImage old) {
    super.didUpdateWidget(old);
    if (!identical(old.bytes, widget.bytes)) {
      _safe = imageSafeToDecodeOnce(widget.bytes);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<bool>(
        future: _safe,
        builder: (context, snap) {
          if (snap.data == true) {
            return Image(
              image: GuardedMemoryImage.provider(
                widget.bytes,
                maxDimension: widget.maxDimension,
              ),
              fit: widget.fit,
              gaplessPlayback: true,
            );
          }
          if (snap.data == false) {
            return const ColoredBox(
              color: Colors.black26,
              child: Center(
                child: Icon(Icons.broken_image_outlined, color: Colors.white70),
              ),
            );
          }
          return const SizedBox.shrink();
        },
      );
}
