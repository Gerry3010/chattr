// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Markdown formatting toolbar for the composer (#95 phase 2). Wraps the current
// selection in the composer's TextEditingController with Markdown syntax, so the
// sent text carries the markup that the message bubble renders (phase 1). No
// package/fork change is needed — the app already owns the composer controller.

import 'dart:ui' show ImageFilter;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

typedef _LinkInput = ({String text, String url});

/// Selection to operate on — the real one, or a collapsed caret at the end when
/// the field has never been focused (invalid selection). Pure, so the formatting
/// transforms below are unit-testable without a widget tree.
TextSelection composerSelection(TextEditingValue value) =>
    value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);

/// Wraps the selection with [left]/[right]. Empty selection ⇒ inserts the
/// markers and parks the caret between them so the user can type inside.
TextEditingValue mdWrap(TextEditingValue value, String left, String right) {
  final text = value.text;
  final sel = composerSelection(value);
  final selected = text.substring(sel.start, sel.end);
  final base = sel.start + left.length;
  return TextEditingValue(
    text: text.replaceRange(sel.start, sel.end, '$left$selected$right'),
    selection: selected.isEmpty
        ? TextSelection.collapsed(offset: base)
        : TextSelection(baseOffset: base, extentOffset: base + selected.length),
  );
}

/// Prefixes every line the selection touches with [prefix] (e.g. "- ").
TextEditingValue mdLinePrefix(TextEditingValue value, String prefix) {
  final text = value.text;
  final sel = composerSelection(value);
  final lineStart =
      sel.start == 0 ? 0 : text.lastIndexOf('\n', sel.start - 1) + 1;
  var lineEnd = text.indexOf('\n', sel.end);
  if (lineEnd == -1) lineEnd = text.length;
  final prefixed = text
      .substring(lineStart, lineEnd)
      .split('\n')
      .map((l) => '$prefix$l')
      .join('\n');
  return TextEditingValue(
    text: text.replaceRange(lineStart, lineEnd, prefixed),
    selection: TextSelection.collapsed(offset: lineStart + prefixed.length),
  );
}

// ── Toggle + active-state (nochmal klicken hebt die Formatierung auf; die
//    Buttons leuchten, wenn der Cursor in der Formatierung steht) ────────────

int _lineStartOf(String text, int offset) =>
    offset == 0 ? 0 : text.lastIndexOf('\n', offset - 1) + 1;

int _lineEndOf(String text, int offset) {
  final e = text.indexOf('\n', offset);
  return e == -1 ? text.length : e;
}

/// Maximal runs of `*` within `[ls, le)` as `[offset, length]`. `***` is one
/// run of length 3 — the key to handling bold+italic mixtures correctly.
List<List<int>> _starRuns(String text, int ls, int le) {
  final runs = <List<int>>[];
  var i = ls;
  while (i < le) {
    if (text.codeUnitAt(i) == 0x2A) {
      var j = i;
      while (j < le && text.codeUnitAt(j) == 0x2A) {
        j++;
      }
      runs.add([i, j - i]);
      i = j;
    } else {
      i++;
    }
  }
  return runs;
}

/// `[bold, italic]` state accumulated from every `*` run before [offset]. A run
/// of length N toggles italic when N is odd and bold when N÷2 is odd, so
/// `*`→italic, `**`→bold, `***`→both — mixtures stay correct. A run the caret
/// sits *inside* only counts the stars left of the caret (so an empty `****`
/// with the caret between still reads as bold).
List<bool> _emphasisBefore(String text, int ls, int le, int offset) {
  var bold = false, italic = false;
  for (final r in _starRuns(text, ls, le)) {
    final start = r[0], len = r[1];
    if (start >= offset) break;
    final eff = (start + len <= offset) ? len : offset - start;
    if (eff.isOdd) italic = !italic;
    if ((eff ~/ 2).isOdd) bold = !bold;
  }
  return [bold, italic];
}

bool _codeActiveBefore(String text, int ls, int le, int offset) {
  var count = 0;
  for (var i = ls; i < offset && i < le; i++) {
    if (text.codeUnitAt(i) == 0x60) count++;
  }
  return count.isOdd;
}

/// Whether [marker] formatting is active at the caret (`**`=bold, `*`=italic,
/// `` ` ``=code). Drives the active button highlight; mixture-aware.
bool mdIsWrapActive(TextEditingValue value, String marker) {
  final text = value.text;
  final sel = composerSelection(value);
  final ls = _lineStartOf(text, sel.start);
  final le = _lineEndOf(text, sel.start);
  if (marker == '`') return _codeActiveBefore(text, ls, le, sel.start);
  final st = _emphasisBefore(text, ls, le, sel.start);
  return marker == '**' ? st[0] : st[1];
}

/// Toggle [marker] wrapping: add when inactive, else strip exactly this
/// emphasis while preserving any co-located one — so toggling bold off
/// `***x***` yields `*x*` (italic kept), and toggling italic yields `**x**`.
TextEditingValue mdToggleWrap(TextEditingValue value, String marker) {
  if (!mdIsWrapActive(value, marker)) return mdWrap(value, marker, marker);
  final text = value.text;
  final sel = composerSelection(value);
  final ls = _lineStartOf(text, sel.start);
  final le = _lineEndOf(text, sel.end);

  if (marker == '`') {
    final positions = <int>[
      for (var i = ls; i < le; i++)
        if (text.codeUnitAt(i) == 0x60) i,
    ];
    int? open, close;
    for (final p in positions) {
      if (p < sel.start) open = p;
    }
    for (final p in positions) {
      if (p >= sel.end) {
        close = p;
        break;
      }
    }
    if (open == null || close == null) return mdWrap(value, marker, marker);
    var t = text.replaceRange(close, close + 1, '');
    t = t.replaceRange(open, open + 1, '');
    return TextEditingValue(
      text: t,
      selection:
          TextSelection(baseOffset: sel.start - 1, extentOffset: sel.end - 1),
    );
  }

  // Asterisk emphasis: strength 1 (italic) or 2 (bold). Remove that many stars
  // from the run that opens the span and the run that closes it — leaving any
  // stronger/weaker co-located emphasis intact.
  final s = marker.length;
  final runs = _starRuns(text, ls, le);
  // Empty span: a single run straddles the caret with ≥s stars on each side
  // (e.g. the caret between an empty `****`). Strip s stars from each side.
  for (final r in runs) {
    final rs = r[0], rl = r[1];
    if (rs < sel.start &&
        rs + rl > sel.end &&
        sel.start - rs >= s &&
        rs + rl - sel.end >= s) {
      var t = text.replaceRange(sel.end, sel.end + s, '');
      t = t.replaceRange(sel.start - s, sel.start, '');
      return TextEditingValue(
        text: t,
        selection: TextSelection(
          baseOffset: sel.start - s,
          extentOffset: sel.end - s,
        ),
      );
    }
  }
  List<int>? open;
  for (final r in runs) {
    if (r[0] < sel.start) open = r;
  }
  List<int>? close;
  for (final r in runs) {
    if (r[0] >= sel.end) {
      close = r;
      break;
    }
  }
  if (open == null || close == null || open[1] < s || close[1] < s) {
    return mdWrap(value, marker, marker); // unbalanced — fall back to wrap
  }
  // Remove from the closing run first (higher offset) so the opening offset
  // stays valid.
  var t = text.replaceRange(close[0], close[0] + s, '');
  t = t.replaceRange(open[0], open[0] + s, '');
  return TextEditingValue(
    text: t,
    selection: TextSelection(
      baseOffset: sel.start - s,
      extentOffset: sel.end - s,
    ),
  );
}

/// Whether the caret's line already starts with [prefix] (list button state).
bool mdIsLineActive(TextEditingValue value, String prefix) {
  final text = value.text;
  final sel = composerSelection(value);
  final ls = _lineStartOf(text, sel.start);
  return text.startsWith(prefix, ls);
}

/// Toggle a line [prefix] on every line the selection touches: strip it when
/// all those lines already have it, else add it.
TextEditingValue mdToggleLinePrefix(TextEditingValue value, String prefix) {
  final text = value.text;
  final sel = composerSelection(value);
  final ls = _lineStartOf(text, sel.start);
  final le = _lineEndOf(text, sel.end);
  final lines = text.substring(ls, le).split('\n');
  final allPrefixed = lines.every((l) => l.startsWith(prefix));
  if (!allPrefixed) return mdLinePrefix(value, prefix);
  final stripped = lines.map((l) => l.substring(prefix.length)).join('\n');
  return TextEditingValue(
    text: text.replaceRange(ls, le, stripped),
    selection: TextSelection.collapsed(offset: ls + stripped.length),
  );
}

class MarkdownComposerToolbar extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool previewEnabled;
  final VoidCallback onTogglePreview;

  const MarkdownComposerToolbar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.previewEnabled,
    required this.onTogglePreview,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Rebuild on every selection/text change so the active-state highlights
    // track the caret. (The controller notifies on selection moves too.)
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        // The composer sits on the chat wallpaper, so without its own fill the
        // toolbar icons floated over the messages behind them (unreadable).
        // Give it a frosted-glass bar — a translucent surface tint over a
        // backdrop blur — so the chat behind stays hinted at but the icons
        // read cleanly.
        return Padding(
          padding: const EdgeInsets.only(top: 4),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
              child: Container(
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
                child: Row(
                  children: [
                    _button(context, Icons.format_bold, 'chat_view.md.bold',
                        () => _toggleWrap('**'),
                        active: mdIsWrapActive(value, '**')),
                    _button(context, Icons.format_italic, 'chat_view.md.italic',
                        () => _toggleWrap('*'),
                        active: mdIsWrapActive(value, '*')),
                    _button(context, Icons.code, 'chat_view.md.code',
                        () => _toggleWrap('`'),
                        active: mdIsWrapActive(value, '`')),
                    _button(context, Icons.link, 'chat_view.md.link',
                        () => _insertLink(context)),
                    _button(context, Icons.format_list_bulleted,
                        'chat_view.md.list', () => _toggleLinePrefix('- '),
                        active: mdIsLineActive(value, '- ')),
                    const Spacer(),
                    IconButton(
                      key: const ValueKey('md_preview_toggle'),
                      tooltip: 'chat_view.md.preview'.tr(),
                      iconSize: 20,
                      icon: Icon(previewEnabled
                          ? Icons.visibility
                          : Icons.visibility_off),
                      color: previewEnabled
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                      onPressed: onTogglePreview,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _button(
    BuildContext context,
    IconData icon,
    String tooltipKey,
    VoidCallback onTap, {
    bool active = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: tooltipKey.tr(),
      iconSize: 20,
      icon: Icon(icon),
      isSelected: active,
      style: active
          ? IconButton.styleFrom(backgroundColor: scheme.primary.withValues(alpha: 0.18))
          : null,
      color: active ? scheme.primary : scheme.onSurfaceVariant,
      onPressed: onTap,
    );
  }

  void _toggleWrap(String marker) {
    controller.value = mdToggleWrap(controller.value, marker);
    focusNode.requestFocus();
  }

  void _toggleLinePrefix(String prefix) {
    controller.value = mdToggleLinePrefix(controller.value, prefix);
    focusNode.requestFocus();
  }

  Future<void> _insertLink(BuildContext context) async {
    final value = controller.value;
    final text = value.text;
    final sel = composerSelection(value);
    final result = await showDialog<_LinkInput>(
      context: context,
      builder: (_) => _LinkDialog(initialText: text.substring(sel.start, sel.end)),
    );
    if (result == null) return;
    final label = result.text.isEmpty ? result.url : result.text;
    final md = '[$label](${result.url})';
    controller.value = TextEditingValue(
      text: text.replaceRange(sel.start, sel.end, md),
      selection: TextSelection.collapsed(offset: sel.start + md.length),
    );
    focusNode.requestFocus();
  }
}

class _LinkDialog extends StatefulWidget {
  final String initialText;
  const _LinkDialog({required this.initialText});

  @override
  State<_LinkDialog> createState() => _LinkDialogState();
}

class _LinkDialogState extends State<_LinkDialog> {
  late final TextEditingController _text =
      TextEditingController(text: widget.initialText);
  final TextEditingController _url = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('chat_view.md.link_title'.tr()),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _text,
            decoration: InputDecoration(
              labelText: 'chat_view.md.link_text'.tr(),
            ),
          ),
          TextField(
            key: const ValueKey('md_link_url'),
            controller: _url,
            autofocus: true,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: 'chat_view.md.link_url'.tr(),
              hintText: 'https://…',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('common.cancel'.tr()),
        ),
        FilledButton(
          onPressed: () {
            final url = _url.text.trim();
            if (url.isEmpty) return;
            Navigator.pop<_LinkInput>(
              context,
              (text: _text.text.trim(), url: url),
            );
          },
          child: Text('chat_view.md.link_insert'.tr()),
        ),
      ],
    );
  }
}
