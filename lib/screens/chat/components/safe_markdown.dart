// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/gestures.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

import '../../../features/messages/message_links.dart';
import '../../../features/messages/message_markdown.dart';
import '../../../features/mentions/mention_spans.dart';

/// Renders the safe markdown subset (see [message_markdown]) into a widget tree.
///
/// Supported: **bold**, *italic*, ~~strike~~, `inline code`, fenced/indented
/// code blocks, headings, ordered/unordered lists, blockquotes, and
/// `[text](http(s)://…)` links. Bare `http(s)` URLs inside the text are made
/// tappable too. Deliberately unsupported for safety: raw HTML (escaped to
/// text upstream) and images (`img` nodes are dropped) — nothing untrusted is
/// ever fetched.
class SafeMarkdown extends StatefulWidget {
  const SafeMarkdown({
    super.key,
    required this.data,
    required this.textColor,
    required this.linkColor,
    this.fontSize = 16,
    this.mentionUsernames = const {},
    this.mentionColor,
    this.selfMentionTokens = const {},
  });

  final String data;
  final Color textColor;
  final Color linkColor;
  final double fontSize;

  /// Member usernames to highlight as `@mentions` in the text (1.10). Empty
  /// disables highlighting (e.g. 1:1 chats, composer preview).
  final Set<String> mentionUsernames;

  /// Colour for a highlighted `@mention`; falls back to [linkColor].
  final Color? mentionColor;

  /// The subset of [mentionUsernames] that means the reader — those mentions
  /// get a tinted ground so „ich bin gemeint" is visible without reading.
  /// Empty on own messages and outside chats.
  final Set<String> selfMentionTokens;

  @override
  State<SafeMarkdown> createState() => _SafeMarkdownState();
}

/// Hard cap on nested-block recursion (blockquotes). Legitimate messages never
/// approach this; a crafted deeply-nested message is rendered as plain text past
/// the cap so the widget tree can't explode. (The parser-side length cap in
/// [parseMarkdownNodes] already prevents the pathological parse itself.)
const int _kMaxNestDepth = 16;

/// Turn HTML entities back into their characters at the render boundary.
///
/// The parser runs with `encodeHtml: true` (see [message_markdown]), which
/// HTML-escapes text and code content: `"`→`&quot;`, `&`→`&amp;`, `<`→`&lt;`,
/// `>`→`&gt;`, `'`→`&#39;`. That is correct when emitting an HTML *string*, but
/// we render to Flutter widgets — `Text`/`TextSpan` are not an HTML sink, so an
/// un-decoded entity shows literally (a peer's `` `"s"` `` renders as
/// `&quot;s&quot;`). Decoding here is safe: the result is still plain text in a
/// widget, so a message that literally contained `<script>` just displays the
/// characters `<script>`; nothing is ever fetched or executed.
///
/// `&amp;` is decoded LAST so a message that really contained an entity (e.g.
/// the six characters `&lt;`, escaped by the parser to `&amp;lt;`) round-trips
/// back to `&lt;` instead of being double-decoded to `<`.
String _decodeEntities(String s) {
  if (!s.contains('&')) return s; // fast path: nothing was escaped
  return s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&amp;', '&');
}

class _SafeMarkdownState extends State<SafeMarkdown> {
  final List<TapGestureRecognizer> _recognizers = [];

  // Parse ONCE per distinct message, not on every build — build() runs on every
  // frame during scrolling and the composer preview rebuilds on every keystroke.
  late List<md.Node> _nodes = parseMarkdownNodes(widget.data);

  @override
  void didUpdateWidget(SafeMarkdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data != widget.data) {
      _nodes = parseMarkdownNodes(widget.data);
    }
  }

  @override
  void dispose() {
    _clearRecognizers();
    super.dispose();
  }

  void _clearRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  TextStyle get _base =>
      TextStyle(color: widget.textColor, fontSize: widget.fontSize);

  Color get _codeBg => widget.textColor.withValues(alpha: 0.12);

  @override
  Widget build(BuildContext context) {
    _clearRecognizers();
    final blocks = _blocks(_nodes, 0);
    // The parser can legitimately yield NOTHING for text that is not empty:
    // [parseMarkdownNodes] declines anything past kMaxMarkdownChars, and it
    // swallows a parser error on pathological nesting. Both are deliberate
    // hardening — but the caller has already committed to this widget by then
    // (a long message that merely @-mentions someone is routed here, length be
    // damned), so returning an empty Column produced a BUBBLE WITH NOTHING IN
    // IT. Seen in the wild 2026-08-05, and it reads as "the message never
    // arrived" rather than "the formatting was skipped".
    //
    // Falling back to plain text keeps the guarantee that matters: whatever a
    // peer sent is READABLE. Links and @mentions still work, because those are
    // resolved on the raw string, not on the AST.
    if (blocks.isEmpty && widget.data.isNotEmpty) {
      return Text.rich(
        TextSpan(style: _base, children: _linkifyPlain(widget.data, _base)),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: blocks,
    );
  }

  // ---- block level ---------------------------------------------------------

  List<Widget> _blocks(List<md.Node> nodes, int depth) {
    final widgets = <Widget>[];
    for (final node in nodes) {
      final w = _block(node, depth);
      if (w != null) widgets.add(w);
    }
    return widgets;
  }

  Widget? _block(md.Node node, int depth) {
    if (node is md.Text) {
      final t = _decodeEntities(node.text).trim();
      if (t.isEmpty) return null;
      return _pad(
        Text.rich(TextSpan(style: _base, children: _mentionSpans(t, _base))),
      );
    }
    if (node is! md.Element) return null;
    final children = node.children ?? const [];
    switch (node.tag) {
      case 'p':
        return _pad(Text.rich(_inline(children, _base)));
      case 'h1':
      case 'h2':
      case 'h3':
      case 'h4':
      case 'h5':
      case 'h6':
        final level = int.parse(node.tag.substring(1));
        final scale = {1: 1.5, 2: 1.35, 3: 1.2}[level] ?? 1.1;
        return _pad(
          Text.rich(
            _inline(
              children,
              _base.copyWith(
                fontSize: widget.fontSize * scale,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        );
      case 'ul':
        return _pad(_list(children, ordered: false));
      case 'ol':
        return _pad(_list(children, ordered: true));
      case 'blockquote':
        // Cap nesting so a crafted deeply-nested quote can't explode the widget
        // tree — render the rest as plain text past the limit.
        if (depth >= _kMaxNestDepth) {
          final t = _plainText(node).trim();
          return t.isEmpty
              ? null
              : _pad(Text.rich(TextSpan(style: _base, text: t)));
        }
        return _pad(
          Container(
            padding: const EdgeInsets.only(left: 10),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: widget.textColor.withValues(alpha: 0.4),
                  width: 3,
                ),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: _blocks(children, depth + 1),
            ),
          ),
        );
      case 'pre':
        // Fenced/indented code block: <pre><code>…</code></pre>.
        return _pad(
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: _codeBg,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              _plainText(node).replaceFirst(RegExp(r'\n$'), ''),
              style: _base.copyWith(
                fontFamily: 'monospace',
                fontSize: widget.fontSize - 1,
              ),
            ),
          ),
        );
      case 'hr':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Divider(
            height: 1,
            color: widget.textColor.withValues(alpha: 0.3),
          ),
        );
      default:
        // Unknown block → render its inline content so nothing is lost.
        return _pad(Text.rich(_inline(children, _base)));
    }
  }

  Widget _pad(Widget child) =>
      Padding(padding: const EdgeInsets.only(bottom: 2), child: child);

  Widget _list(List<md.Node> items, {required bool ordered}) {
    final rows = <Widget>[];
    var n = 1;
    for (final item in items) {
      if (item is! md.Element || item.tag != 'li') continue;
      final marker = ordered ? '${n++}.' : '•';
      rows.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 1),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 22,
                child: Text(
                  '$marker ',
                  style: _base,
                  textAlign: TextAlign.right,
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text.rich(_inline(item.children ?? const [], _base)),
              ),
            ],
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: rows,
    );
  }

  // ---- inline level --------------------------------------------------------

  TextSpan _inline(List<md.Node> nodes, TextStyle style) {
    return TextSpan(
      children: [for (final n in nodes) ..._inlineSpans(n, style)],
    );
  }

  List<InlineSpan> _inlineSpans(md.Node node, TextStyle style) {
    if (node is md.Text) {
      return _linkifyPlain(_decodeEntities(node.text), style);
    }
    if (node is! md.Element) return const [];
    final children = node.children ?? const [];
    switch (node.tag) {
      case 'strong':
        return [_inline(children, style.copyWith(fontWeight: FontWeight.bold))];
      case 'em':
        return [_inline(children, style.copyWith(fontStyle: FontStyle.italic))];
      case 'del':
        return [
          _inline(
            children,
            style.copyWith(decoration: TextDecoration.lineThrough),
          ),
        ];
      case 'code':
        return [
          TextSpan(
            text: _plainText(node),
            style: style.copyWith(
              fontFamily: 'monospace',
              backgroundColor: _codeBg,
            ),
          ),
        ];
      case 'a':
        return [_link(node, style)];
      case 'br':
        return const [TextSpan(text: '\n')];
      case 'img':
        // Never fetch remote images. Show the alt text (if any) as plain text.
        final alt = node.attributes['alt'];
        return (alt == null || alt.isEmpty)
            ? const []
            : [TextSpan(text: _decodeEntities(alt), style: style)];
      default:
        return [_inline(children, style)];
    }
  }

  InlineSpan _link(md.Element node, TextStyle style) {
    final href = node.attributes['href'];
    final label = _plainText(node);
    final uri = href == null ? null : normalizeUrl(href);
    // Only http/https links are tappable; anything else renders as plain text.
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return TextSpan(text: label, style: style);
    }
    final recognizer = TapGestureRecognizer()
      ..onTap = () => _open(uri, label);
    _recognizers.add(recognizer);
    return TextSpan(
      text: label,
      recognizer: recognizer,
      style: style.copyWith(
        color: widget.linkColor,
        decoration: TextDecoration.underline,
        decorationColor: widget.linkColor,
      ),
    );
  }

  /// Opens [uri]; first says where it really goes when the text claims
  /// something else (CHAT-39).
  Future<void> _open(Uri uri, String label) async {
    if (linkNeedsConfirmation(label, uri)) {
      final go = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('chat_view.link_check_title'.tr()),
          content: Text(
            'chat_view.link_check_body'.tr(args: [uri.host, uri.toString()]),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text('common.cancel'.tr()),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text('chat_view.link_check_open'.tr()),
            ),
          ],
        ),
      );
      if (go != true) return;
    }
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  /// Splits a plain-text run into spans, highlighting `@username` mentions of
  /// known members (1.10) and setting apart those that mean the reader.
  List<InlineSpan> _mentionSpans(String text, TextStyle style) => mentionSpans(
    text,
    style,
    usernames: widget.mentionUsernames,
    mentionColor: widget.mentionColor ?? widget.linkColor,
    selfTokens: widget.selfMentionTokens,
  );

  /// Split a plain-text run into tappable spans for any bare http(s) URLs and
  /// e-mail addresses, then highlight `@mentions` inside the rest.
  List<InlineSpan> _linkifyPlain(String text, TextStyle style) {
    if (text.isEmpty) return const [];
    final spans = <InlineSpan>[];
    var index = 0;
    for (final match in linkTokenPattern.allMatches(text)) {
      if (match.start > index) {
        spans.addAll(_mentionSpans(text.substring(index, match.start), style));
      }
      final raw = match.group(0)!;
      final url = raw.replaceFirst(RegExp(r'[.,;:!?]+$'), '');
      final uri = normalizeUrl(url);
      if (uri == null) {
        spans.add(TextSpan(text: raw, style: style));
      } else {
        final recognizer = TapGestureRecognizer()
          ..onTap = () => launchUrl(uri, mode: LaunchMode.externalApplication);
        _recognizers.add(recognizer);
        spans.add(
          TextSpan(
            text: url,
            recognizer: recognizer,
            style: style.copyWith(
              color: widget.linkColor,
              decoration: TextDecoration.underline,
              decorationColor: widget.linkColor,
            ),
          ),
        );
        if (url.length < raw.length) {
          spans.add(TextSpan(text: raw.substring(url.length), style: style));
        }
      }
      index = match.end;
    }
    if (index < text.length) {
      spans.addAll(_mentionSpans(text.substring(index), style));
    }
    return spans;
  }

  String _plainText(md.Node node) {
    if (node is md.Text) return _decodeEntities(node.text);
    if (node is md.Element) {
      return (node.children ?? const []).map(_plainText).join();
    }
    return '';
  }
}
