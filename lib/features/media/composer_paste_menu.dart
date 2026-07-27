// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import 'clipboard_paste.dart';

/// App-side composer context-menu builder that surfaces a media "Einfügen"
/// entry (#92).
///
/// Why this exists: on iOS there is no Cmd+V, and the native text-selection
/// toolbar only offers "Einfügen" for *text* — so an image sitting in the
/// clipboard looks un-pasteable. WhatsApp adds its own paste entry to the
/// composer menu; this mirrors that. On desktop/web the Cmd/Ctrl+V hook
/// ([SendMessageConfiguration.onPaste]) already covers paste, but the menu
/// entry is harmless there and driven purely by clipboard content.
///
/// Wired into the chatview fork's composer TextField via the p9 passthrough
/// (`composerContextMenuBuilder` on `SendMessageConfiguration`).
///
/// The sync/async gap: [TextField.contextMenuBuilder] is synchronous, but
/// probing the clipboard ([clipboardHasPasteableMedia]) is async. We resolve it
/// with a cached [ValueNotifier] that is refreshed each time the menu opens;
/// the returned [ValueListenableBuilder] rebuilds the toolbar *in place* the
/// instant the probe resolves (~immediately), so the entry appears without the
/// builder ever blocking.
final _ClipboardMediaProbe _clipboardMediaProbe = _ClipboardMediaProbe();

/// Builds the composer's context menu, appending a media-paste entry when the
/// clipboard holds a pasteable image/file.
///
/// [onPasteMedia] runs the authoritative clipboard read (typically
/// [pasteClipboardMedia]) and returns `true` when it handled media. It is only
/// offered when the probe reports media present; if the optimistic probe was
/// wrong (`false` returned), a brief "nothing to paste" snackbar is shown.
Widget buildComposerContextMenu(
  BuildContext context,
  EditableTextState editableState, {
  required Future<bool> Function() onPasteMedia,
  required bool markdownBarEnabled,
  required VoidCallback onToggleMarkdownBar,
}) {
  // Fire-and-forget: refresh the cached clipboard state whenever the menu
  // opens. The ValueListenableBuilder below updates the live toolbar the moment
  // it resolves. The probe's own re-entrancy guard makes repeat calls cheap.
  _clipboardMediaProbe.refresh();

  return ValueListenableBuilder<bool>(
    valueListenable: _clipboardMediaProbe,
    builder: (context, hasMedia, _) {
      final items = List<ContextMenuButtonItem>.from(
        editableState.contextMenuButtonItems,
      );
      if (hasMedia) {
        items.add(
          ContextMenuButtonItem(
            label: 'media.paste'.tr(),
            onPressed: () async {
              editableState.hideToolbar();
              final handled = await onPasteMedia();
              if (!handled && context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('media.paste_empty'.tr())),
                );
              }
            },
          ),
        );
      }
      // Global toggle for the Markdown formatting bar (off by default).
      items.add(
        ContextMenuButtonItem(
          label: (markdownBarEnabled
                  ? 'chat_view.markdown_bar_hide'
                  : 'chat_view.markdown_bar_show')
              .tr(),
          onPressed: () {
            editableState.hideToolbar();
            onToggleMarkdownBar();
          },
        ),
      );
      return AdaptiveTextSelectionToolbar.buttonItems(
        anchors: editableState.contextMenuAnchors,
        buttonItems: items,
      );
    },
  );
}

/// Cached clipboard-media presence, refreshed on demand. [ValueNotifier] only
/// notifies on an actual change, so a rebuild that re-probes but finds the same
/// state does not loop; [_running] coalesces overlapping reads.
class _ClipboardMediaProbe extends ValueNotifier<bool> {
  _ClipboardMediaProbe() : super(false);

  bool _running = false;

  Future<void> refresh() async {
    if (_running) return;
    _running = true;
    try {
      value = await clipboardHasPasteableMedia();
    } catch (_) {
      value = false;
    } finally {
      _running = false;
    }
  }
}
