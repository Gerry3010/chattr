// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:markdown/markdown.dart' as md;

/// Markdown parsing for the safe message subset (Task #95).
///
/// We deliberately support only an inline-safe subset — bold, italic,
/// strikethrough, inline code, fenced/indented code blocks, headings, lists,
/// blockquotes and `[text](http(s)://…)` links. There is **no raw HTML** and
/// **no image rendering**: `encodeHtml: true` turns any `<tag>` into literal
/// text, and the renderer simply drops `img` nodes. So a message can never make
/// the app fetch or execute anything untrusted — important for an E2E chat.

/// The single shared document config. Standard CommonMark inline/block syntaxes
/// plus GFM strikethrough; raw HTML is escaped (encodeHtml). No autolink
/// extension, so bare URLs are left to the existing link-preview path — only
/// explicit `[text](url)` markdown links become link nodes here.
final md.Document _document = md.Document(
  inlineSyntaxes: [md.StrikethroughSyntax()],
  encodeHtml: true,
);

/// Messages longer than this are never treated as markdown — they render as
/// plain text instead. Chat messages are short, so this is generous; it caps
/// the parser's worst-case cost and, crucially, keeps a crafted deeply-nested
/// message (e.g. thousands of `> ` / list markers a peer could send over the
/// E2E channel) from StackOverflowing or freezing the UI-thread parse. At this
/// length the worst-case nested parse stays well under the crash depth.
const int kMaxMarkdownChars = 2000;

// Memoize the markdown classification. hasMarkdown(text) is a pure function of
// text, but it is called repeatedly for the SAME message — routing in
// _convertMessage AND rendering in _customMessageBuilder, on every chat open,
// rebuild and scroll frame. Without a cache, a peer who floods pathological
// messages makes each chat open re-parse all of them on the UI thread (a
// scaling freeze). FIFO-bounded so it can't grow unboundedly across a session.
final Map<String, bool> _hasMarkdownCache = <String, bool>{};
const int _hasMarkdownCacheCap = 512;

/// Parse [text] into a markdown AST (block-level nodes). Defensive: returns an
/// empty list for over-long input, and swallows any parser error (e.g. a
/// StackOverflow on pathological nesting) so a crafted message can never crash
/// or freeze the renderer.
List<md.Node> parseMarkdownNodes(String text) {
  if (text.length > kMaxMarkdownChars) return const [];
  try {
    return _document.parseLines(const LineSplitter().convert(text));
  } catch (_) {
    return const [];
  }
}

/// The AST element tags that represent actual formatting (as opposed to a plain
/// paragraph of text). If none of these appear, the message has no markdown
/// worth rendering and stays on chatview's default text bubble.
const Set<String> _formattingTags = {
  'strong', 'em', 'del', 'code', 'a',
  'ul', 'ol', 'li', 'blockquote', 'pre',
  'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'hr',
};

/// Whether [text] contains renderable markdown. Parses and looks for a real
/// formatting element — avoids the false positives a regex would hit on stray
/// `*` or `_` in ordinary prose.
bool hasMarkdown(String text) {
  if (text.isEmpty || text.length > kMaxMarkdownChars) return false;
  final cached = _hasMarkdownCache[text];
  if (cached != null) return cached;
  final result = _detectMarkdown(text);
  if (_hasMarkdownCache.length >= _hasMarkdownCacheCap) {
    _hasMarkdownCache.remove(_hasMarkdownCache.keys.first); // evict oldest (FIFO)
  }
  _hasMarkdownCache[text] = result;
  return result;
}

bool _detectMarkdown(String text) {
  // Cheap pre-filter: if none of the trigger characters are present, skip the
  // parse entirely (the common case for plain chat messages).
  if (!RegExp(r'[*_~`\[#>]|^\s*[-+]\s|^\s*\d+\.\s', multiLine: true)
      .hasMatch(text)) {
    return false;
  }
  return _containsFormatting(parseMarkdownNodes(text));
}

bool _containsFormatting(List<md.Node> nodes) {
  for (final node in nodes) {
    if (node is md.Element) {
      if (_formattingTags.contains(node.tag)) return true;
      final children = node.children;
      if (children != null && _containsFormatting(children)) return true;
    }
  }
  return false;
}
