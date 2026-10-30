// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pro_image_editor/pro_image_editor.dart';

/// Full-screen image editor shown before sending a picked/captured image
/// (crop/rotate/flip, paint incl. blur & pixelate for censoring, text, filters,
/// tune, emoji, stickers). Thin wrapper around [ProImageEditor]: bytes in →
/// edited bytes out.
///
/// Pops with the edited [Uint8List] when the user confirms (checkmark), or with
/// `null` when they back out (the caller then keeps the original bytes).
///
/// When [ProImageEditorCallbacks.onCloseEditor] is supplied, the package hands
/// close control to us for BOTH the done and cancel paths (see main_editor.dart
/// ~2854/2910), so this widget owns the single [Navigator.pop].
class ImageEditorScreen extends StatefulWidget {
  final Uint8List bytes;

  const ImageEditorScreen({super.key, required this.bytes});

  @override
  State<ImageEditorScreen> createState() => _ImageEditorScreenState();
}

class _ImageEditorScreenState extends State<ImageEditorScreen> {
  /// Set only when the user confirms; stays null on cancel → pop null.
  Uint8List? _result;

  @override
  Widget build(BuildContext context) {
    return ProImageEditor.memory(
      widget.bytes,
      configs: ProImageEditorConfigs(
        // Match the app chrome; the editor falls back to its own dark theme
        // when null, but we want the accent colors to line up.
        theme: Theme.of(context),
      ),
      callbacks: ProImageEditorCallbacks(
        // Fires on confirm, before onCloseEditor — capture the export bytes.
        onImageEditingComplete: (bytes) async => _result = bytes,
        // Fires for both confirm and cancel of the MAIN editor. Sub-editors
        // (paint/text/…) report their own modes and must NOT pop this route.
        onCloseEditor: (mode) {
          if (mode == EditorMode.main && mounted) {
            Navigator.of(context).pop(_result);
          }
        },
      ),
    );
  }
}
