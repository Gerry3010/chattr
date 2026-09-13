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

/// Hard ceiling on what goes near the parser at all — a bound on plain cost,
/// not a safety rule.
///
/// It used to be 2000 and was the ONLY guard, which got the trade-off backwards
/// in both directions: an ordinary long message (an agent's write-up, a pasted
/// note) lost its formatting for being wordy, while 300 characters of `>>>>…` —
/// the thing the cap was written for — sailed straight through. Length is not
/// the danger. [_isPathological] measures the danger; this only stops something
/// absurd from being scanned at all.
const int kMaxMarkdownChars = 20000;

/// Maximum block nesting (`>` quotes, list indentation) before a message is
/// refused.
///
/// This is the real hazard: `parseLines` descends recursively per nesting
/// level, on the UI thread, over a string a peer controls end-to-end. Deep
/// enough and it blows the stack or stalls a frame. Twelve is far past anything
/// a person writes and far short of anything that hurts.
const int kMaxMarkdownDepth = 12;

/// Above this share of markdown control characters a message is refused.
///
/// Catches the shape depth alone misses: a wall of `*`/`_`/`[`/`` ` `` that
/// never nests but makes the inline scanner chew through delimiter runs. Real
/// prose — even heavily formatted prose, tables included — stays far below.
const double kMaxMarkdownMarkerDensity = 0.35;

/// The smallest message the density rule applies to. Short strings are cheap
/// whatever they contain, and `**hi**` (6 of 6 characters are markers) would
/// otherwise be rejected as an attack.
const int kMarkerDensityMinChars = 200;

/// Is [text] shaped like an attack rather than a message?
///
/// Cheap: one pass, no parse, no regex backtracking. Deliberately structural —
/// it asks "how deep" and "how dense", never "how long".
bool _isPathological(String text) {
  var maxDepth = 0;
  var markers = 0;
  var lineStart = true;
  var depth = 0;
  var indent = 0;
  // A single space directly after '>' belongs to the quote marker (CommonMark),
  // not to list indentation. Counting it as indentation made twelve honest
  // quote levels look like fifteen.
  var afterQuote = false;

  for (var i = 0; i < text.length; i++) {
    final c = text.codeUnitAt(i);

    if (c == 0x0A) {
      // newline
      lineStart = true;
      depth = 0;
      indent = 0;
      afterQuote = false;
      continue;
    }

    if (lineStart) {
      if (c == 0x20 || c == 0x09) {
        // space / tab
        if (afterQuote) {
          afterQuote = false;
        } else {
          // Four spaces (or one tab) is one list level in CommonMark.
          indent++;
        }
        continue;
      }
      afterQuote = false;
      if (c == 0x3E) {
        // '>'
        depth++;
        afterQuote = true;
        if (depth + indent ~/ 4 > maxDepth) maxDepth = depth + indent ~/ 4;
        continue;
      }
      // First non-prefix character: the line's block depth is settled.
      if (depth + indent ~/ 4 > maxDepth) maxDepth = depth + indent ~/ 4;
      lineStart = false;
    }

    // '*' '_' '~' '`' '[' ']' '#' '>'
    if (c == 0x2A ||
        c == 0x5F ||
        c == 0x7E ||
        c == 0x60 ||
        c == 0x5B ||
        c == 0x5D ||
        c == 0x23 ||
        c == 0x3E) {
      markers++;
    }
  }

  if (maxDepth > kMaxMarkdownDepth) return true;
  if (text.length >= kMarkerDensityMinChars &&
      markers / text.length > kMaxMarkdownMarkerDensity) {
    return true;
  }
  return false;
}

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
  if (text.length > kMaxMarkdownChars || _isPathological(text)) return const [];
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
  if (_isPathological(text)) return false;
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
