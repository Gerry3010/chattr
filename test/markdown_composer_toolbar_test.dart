// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Markdown composer toolbar (#95 phase 2): the pure selection transforms that
// the B/I/Code/List buttons apply. Kept BuildContext-free so they're testable.

import 'package:chattr/screens/chat/components/markdown_composer_toolbar.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TextEditingValue v(String text, {int? base, int? extent}) => TextEditingValue(
        text: text,
        selection: base == null
            ? const TextSelection.collapsed(offset: -1) // invalid (never focused)
            : TextSelection(baseOffset: base, extentOffset: extent ?? base),
      );

  group('mdWrap', () {
    test('wraps a selection and keeps it selected', () {
      final r = mdWrap(v('hello world', base: 6, extent: 11), '**', '**');
      expect(r.text, 'hello **world**');
      expect(r.text.substring(r.selection.start, r.selection.end), 'world');
    });

    test('empty selection inserts markers with caret between them', () {
      final r = mdWrap(v('hi', base: 2, extent: 2), '`', '`');
      expect(r.text, 'hi``');
      expect(r.selection.isCollapsed, isTrue);
      expect(r.selection.baseOffset, 3);
    });

    test('invalid selection appends at end', () {
      final r = mdWrap(v('abc'), '*', '*');
      expect(r.text, 'abc**');
      expect(r.selection.baseOffset, 4);
    });
  });

  group('mdLinePrefix', () {
    test('prefixes only the caret line', () {
      final r = mdLinePrefix(v('one\ntwo\nthree', base: 5, extent: 5), '- ');
      expect(r.text, 'one\n- two\nthree');
    });

    test('prefixes every line the selection spans', () {
      final r = mdLinePrefix(v('a\nb\nc', base: 0, extent: 5), '- ');
      expect(r.text, '- a\n- b\n- c');
    });

    test('handles a caret at offset 0', () {
      final r = mdLinePrefix(v('x\ny', base: 0, extent: 0), '- ');
      expect(r.text, '- x\ny');
    });
  });

  group('mdIsWrapActive (button state)', () {
    test('true when caret is inside a bold span', () {
      // he**llo** — caret at offset 4, between the ** pair
      expect(mdIsWrapActive(v('he**llo**', base: 4, extent: 4), '**'), isTrue);
    });

    test('false when caret is before/after the span', () {
      expect(mdIsWrapActive(v('**hi**', base: 0, extent: 0), '**'), isFalse);
      expect(mdIsWrapActive(v('**hi**', base: 6, extent: 6), '**'), isFalse);
    });

    test('true when a selection is wrapped', () {
      // select "hi" inside **hi**
      expect(mdIsWrapActive(v('**hi**', base: 2, extent: 4), '**'), isTrue);
    });

    test('italic ignores the * that belong to bold **', () {
      // caret inside **bold** must NOT read as italic-active
      expect(mdIsWrapActive(v('**bold**', base: 4, extent: 4), '*'), isFalse);
      // genuine italic *i* is active
      expect(mdIsWrapActive(v('*i*', base: 2, extent: 2), '*'), isTrue);
    });

    test('per-line: a span on another line does not leak', () {
      expect(
        mdIsWrapActive(v('**a**\nbcd', base: 7, extent: 7), '**'),
        isFalse,
      );
    });

    test('code (`) active detection', () {
      expect(mdIsWrapActive(v('a `x` b', base: 3, extent: 3), '`'), isTrue);
      expect(mdIsWrapActive(v('a `x` b', base: 6, extent: 6), '`'), isFalse);
    });
  });

  group('mdIsWrapActive — bold+italic MIXTURES (***) ', () {
    // caret inside ***word*** — offset 4 is between the leading *** and text
    test('*** is BOTH bold and italic active', () {
      final val = v('***word***', base: 4, extent: 4);
      expect(mdIsWrapActive(val, '**'), isTrue, reason: 'bold');
      expect(mdIsWrapActive(val, '*'), isTrue, reason: 'italic');
    });

    test('**bold *italic* end** — caret in italic: both active', () {
      // "**bold *italic* end**" — caret at offset 9 (inside "italic")
      final val = v('**bold *italic* end**', base: 9, extent: 9);
      expect(mdIsWrapActive(val, '**'), isTrue);
      expect(mdIsWrapActive(val, '*'), isTrue);
    });

    test('**bold *italic* end** — caret after italic closes: only bold', () {
      // caret at offset 17 (inside " end", after *italic*)
      final val = v('**bold *italic* end**', base: 17, extent: 17);
      expect(mdIsWrapActive(val, '**'), isTrue);
      expect(mdIsWrapActive(val, '*'), isFalse);
    });
  });

  group('mdToggleWrap — bold+italic MIXTURES', () {
    test('toggle bold OFF ***word*** keeps italic → *word*', () {
      final r = mdToggleWrap(v('***word***', base: 4, extent: 4), '**');
      expect(r.text, '*word*');
    });

    test('toggle italic OFF ***word*** keeps bold → **word**', () {
      final r = mdToggleWrap(v('***word***', base: 4, extent: 4), '*');
      expect(r.text, '**word**');
    });

    test('adding italic on top of bold: select inner, wrap → ***word***', () {
      // "**word**", select "word" (2..6), add italic
      final r = mdToggleWrap(v('**word**', base: 2, extent: 6), '*');
      expect(r.text, '***word***');
    });

    test('full selection round-trip: word → bold → +italic → −italic → −bold', () {
      // The realistic flow keeps the word selected across every toggle.
      var val = v('word', base: 0, extent: 4);
      val = mdToggleWrap(val, '**');
      expect(val.text, '**word**');
      val = mdToggleWrap(val, '*');
      expect(val.text, '***word***');
      val = mdToggleWrap(val, '*'); // remove italic, keep bold
      expect(val.text, '**word**');
      val = mdToggleWrap(val, '**'); // remove bold
      expect(val.text, 'word');
    });

    test('empty ****: caret between reads bold-active and toggles clean', () {
      final val = v('****', base: 2, extent: 2);
      expect(mdIsWrapActive(val, '**'), isTrue);
      final off = mdToggleWrap(val, '**');
      expect(off.text, ''); // empty bold removed, no pile-up
    });
  });

  group('mdToggleWrap', () {
    test('adds markers when inactive (like mdWrap)', () {
      final r = mdToggleWrap(v('hello world', base: 6, extent: 11), '**');
      expect(r.text, 'hello **world**');
      expect(r.text.substring(r.selection.start, r.selection.end), 'world');
    });

    test('removes the enclosing pair when active (selection wrapped)', () {
      // "world" selected inside markers, click bold again → unwrap
      final r = mdToggleWrap(v('hello **world**', base: 8, extent: 13), '**');
      expect(r.text, 'hello world');
      expect(r.text.substring(r.selection.start, r.selection.end), 'world');
    });

    test('removes the pair when the caret is inside (collapsed)', () {
      final r = mdToggleWrap(v('a`code`b', base: 4, extent: 4), '`');
      expect(r.text, 'acodeb');
    });

    test('round-trips: wrap then unwrap restores the original', () {
      final start = v('pick me', base: 0, extent: 4); // "pick" selected
      final wrapped = mdToggleWrap(start, '*');
      expect(wrapped.text, '*pick* me');
      final unwrapped = mdToggleWrap(wrapped, '*');
      expect(unwrapped.text, 'pick me');
    });
  });

  group('mdIsLineActive / mdToggleLinePrefix (list)', () {
    test('active when the caret line starts with the prefix', () {
      expect(mdIsLineActive(v('- item', base: 3, extent: 3), '- '), isTrue);
      expect(mdIsLineActive(v('item', base: 2, extent: 2), '- '), isFalse);
    });

    test('toggle adds then removes the prefix', () {
      final added = mdToggleLinePrefix(v('item', base: 2, extent: 2), '- ');
      expect(added.text, '- item');
      final removed = mdToggleLinePrefix(added, '- ');
      expect(removed.text, 'item');
    });

    test('removes only when ALL spanned lines have it', () {
      // one line prefixed, one not → adds to both (not a full toggle-off)
      final r = mdToggleLinePrefix(v('- a\nb', base: 0, extent: 5), '- ');
      expect(r.text, '- - a\n- b');
    });

    test('toggles off a multi-line list', () {
      final r = mdToggleLinePrefix(v('- a\n- b', base: 0, extent: 7), '- ');
      expect(r.text, 'a\nb');
    });
  });
}
