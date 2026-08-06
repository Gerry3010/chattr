// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:typed_data';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:super_clipboard/super_clipboard.dart';

import 'clipboard_probe.dart';
import 'media_attachment.dart';
import 'widgets/attach_menu.dart' show AttachSend, sendMediaBytes;

/// Clipboard formats we accept for pasting, in priority order (images first —
/// the common "paste a screenshot" case — then documents, media and archives).
/// Each entry pairs a super_clipboard [FileFormat] with the file extension we
/// give the pasted bytes so [mimeForExtension] can label them.
const List<(FileFormat, String)> _pasteFormats = [
  (Formats.png, 'png'),
  (Formats.jpeg, 'jpg'),
  (Formats.gif, 'gif'),
  (Formats.webp, 'webp'),
  (Formats.tiff, 'tiff'),
  (Formats.bmp, 'bmp'),
  (Formats.heic, 'heic'),
  (Formats.svg, 'svg'),
  (Formats.pdf, 'pdf'),
  (Formats.mp4, 'mp4'),
  (Formats.mov, 'mov'),
  (Formats.webm, 'webm'),
  (Formats.mp3, 'mp3'),
  (Formats.wav, 'wav'),
  (Formats.m4a, 'm4a'),
  (Formats.docx, 'docx'),
  (Formats.doc, 'doc'),
  (Formats.xlsx, 'xlsx'),
  (Formats.pptx, 'pptx'),
  (Formats.zip, 'zip'),
  (Formats.csv, 'csv'),
  (Formats.json, 'json'),
];

/// Extensions we can render as an inline preview thumbnail via [Image.memory].
/// (Others — svg/heic/tiff and non-image files — fall back to a file card.)
const Set<String> _previewableExts = {'png', 'jpg', 'gif', 'webp', 'bmp'};

/// Reads an image/file from the clipboard and, after a preview confirmation,
/// sends it through the shared [sendMediaBytes] pipeline (E2E-encrypt + send).
///
/// Returns `true` when the clipboard held pasteable media (even if the user
/// cancelled the preview) so callers can distinguish "handled" from "nothing
/// to paste"; `false` when no supported media was present.
Future<bool> pasteClipboardMedia({
  required BuildContext context,
  required AttachSend onSend,
  String? initialText,
}) async {
  final clipboard = SystemClipboard.instance;
  if (clipboard == null) return false; // clipboard read unsupported here
  final reader = await clipboard.read();

  for (final (format, ext) in _pasteFormats) {
    if (!reader.canProvide(format)) continue;
    final bytes = await _readFile(reader, format);
    // canProvide can be optimistic (format known but data absent) — skip empties.
    if (bytes == null || bytes.isEmpty) continue;

    final fileName = _fileName(await reader.getSuggestedName(), ext);
    if (!context.mounted) return true;
    final confirmed = await _confirmPaste(context, fileName, bytes, ext);
    if (confirmed != true) return true; // cancelled, but media WAS present
    if (!context.mounted) return true;
    await sendMediaBytes(
      context: context,
      onSend: onSend,
      bytes: bytes,
      fileName: fileName,
      mime: mimeForExtension(ext),
      initialText: initialText,
    );
    return true;
  }
  return false;
}

/// Cheap async probe: does the clipboard currently hold media we can paste?
///
/// Used to decide whether to surface the composer's "Einfügen" context-menu
/// entry (see [composer_paste_menu.dart]). Only checks format availability —
/// no bytes are read — so it is fast enough to run each time the menu opens.
/// [canProvide] can be optimistic (format advertised but data absent); for a
/// menu-visibility hint that is acceptable — [pasteClipboardMedia] is the
/// authoritative read and returns `false` if nothing usable is there.
///
/// On iOS this goes through [ClipboardProbe] first: `SystemClipboard.read()`
/// reads clipboard *content*, so on iOS 16+ it pops the paste transparency
/// banner every time the composer menu opens — the native probe answers from
/// `UIPasteboard.hasImages` and never prompts. Everywhere else the probe
/// returns null and we take the portable path below unchanged.
///
/// Note the narrowing on iOS: `hasImages` covers the screenshot/photo case (the
/// reason the entry exists) but not a non-image file — a copied PDF/zip won't
/// surface the entry there. Pasting one still works via the authoritative read;
/// only the proactive hint is image-only. Widening it would mean inspecting
/// `UIPasteboard.types` natively (also prompt-free) — a follow-up if it ever
/// comes up in practice.
Future<bool> clipboardHasPasteableMedia() async {
  final nativeProbe = await ClipboardProbe.hasPasteableMedia();
  if (nativeProbe != null) return nativeProbe;

  final clipboard = SystemClipboard.instance;
  if (clipboard == null) return false; // clipboard read unsupported here
  final reader = await clipboard.read();
  for (final (format, _) in _pasteFormats) {
    if (reader.canProvide(format)) return true;
  }
  return false;
}

/// Awaitable wrapper around the callback-based [DataReader.getFile].
Future<Uint8List?> _readFile(ClipboardReader reader, FileFormat format) {
  final completer = Completer<Uint8List?>();
  final progress = reader.getFile(
    format,
    (file) async {
      try {
        completer.complete(await file.readAll());
      } catch (_) {
        if (!completer.isCompleted) completer.complete(null);
      }
    },
    onError: (_) {
      if (!completer.isCompleted) completer.complete(null);
    },
  );
  if (progress == null) return Future.value(null);
  return completer.future;
}

String _fileName(String? suggested, String ext) {
  final name = suggested?.trim();
  if (name != null && name.isNotEmpty) {
    return name.contains('.') ? name : '$name.$ext';
  }
  return 'pasted.$ext';
}

Future<bool?> _confirmPaste(
  BuildContext context,
  String fileName,
  Uint8List bytes,
  String ext,
) {
  final sizeLabel = _humanSize(bytes.length);
  final canPreview = _previewableExts.contains(ext);
  return showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('media.paste_title'.tr()),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (canPreview)
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: Image.memory(
                  bytes,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => _fileCard(dialogContext, fileName),
                ),
              ),
            )
          else
            _fileCard(dialogContext, fileName),
          const SizedBox(height: 10),
          Text(
            '$fileName · $sizeLabel',
            style: Theme.of(dialogContext).textTheme.bodySmall,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text('common.cancel'.tr()),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text('media.paste_send'.tr()),
        ),
      ],
    ),
  );
}

Widget _fileCard(BuildContext context, String fileName) => Row(
      children: [
        Icon(Icons.insert_drive_file,
            size: 40, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 12),
        Expanded(
          child: Text(fileName, maxLines: 2, overflow: TextOverflow.ellipsis),
        ),
      ],
    );

String _humanSize(int bytes) {
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.round()} KB';
  return '${(kb / 1024).toStringAsFixed(1)} MB';
}
