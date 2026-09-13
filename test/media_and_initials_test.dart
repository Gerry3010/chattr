// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Fast pure-function unit tests (no Supabase / native crypto) — safe to run
// anywhere, including CI. Covers the media descriptor + file-type previews
// (#16/#23) and the avatar-initials guard (#4.6).
//
//   flutter test test/media_and_initials_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/features/identity/identity_color.dart';
import 'package:chattr/features/media/media_attachment.dart';
import 'package:chattr/features/media/widgets/file_type_visuals.dart';
import 'package:chattr/screens/chat/chat_list_screen.dart' show getInitials;

/// WCAG 2.x contrast ratio between two opaque colours.
double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  group('getInitials', () {
    test('returns "?" for empty / whitespace-only names (no RangeError)', () {
      expect(getInitials(''), '?');
      expect(getInitials('   '), '?');
      expect(getInitials('\t\n'), '?');
    });

    test('canonical initials: first + last word, uppercased', () {
      expect(getInitials('alice'), 'A');
      expect(getInitials('Bob Builder'), 'BB');
      expect(getInitials('  charlie  '), 'C');
      expect(getInitials('éric'), 'É');
      expect(getInitials('Anna Maria Muster'), 'AM');
    });
  });

  // Regression guard for the 1.11.1 avatar fix: the chatview fork picked the
  // initials colour with a plain `luminance > 0.5`, the app with the WCAG
  // crossover (~0.179). Same user, same background, different letter colour
  // depending on the screen — and white at ~1.9:1 on the light hues.
  group('IdentityColor.foregroundOn', () {
    test('never falls below AA-large (3:1) on any palette hue', () {
      for (var seed = 0; seed < 720; seed++) {
        final bg = IdentityColor.forSeed('user-$seed');
        final fg = IdentityColor.foregroundOn(bg);
        expect(
          _contrast(bg, fg),
          greaterThanOrEqualTo(3.0),
          reason: 'seed $seed → bg $bg / fg $fg',
        );
      }
    });

    test('picks the higher-contrast option, not a naive >0.5 threshold', () {
      for (var seed = 0; seed < 720; seed++) {
        final bg = IdentityColor.forSeed('user-$seed');
        final fg = IdentityColor.foregroundOn(bg);
        final other = fg == Colors.white ? Colors.black : Colors.white;
        expect(_contrast(bg, fg), greaterThanOrEqualTo(_contrast(bg, other)));
      }
    });

    test('a mid-luminance hue gets black — the old fork rule said white', () {
      // HSL(60°, .55, .55): luminance ≈0.56 → white would be ~1.7:1.
      const amber = Color(0xFFCBCB4D);
      expect(IdentityColor.foregroundOn(amber), Colors.black);
      expect(amber.computeLuminance(), greaterThan(0.179));
    });
  });

  group('IdentityColor.initialsTextStyle', () {
    test('scales with the circle and matches the fork ratio (0.8 × radius)', () {
      const bg = Color(0xFF3366CC);
      expect(IdentityColor.initialsTextStyle(20, bg).fontSize, 16);
      expect(IdentityColor.initialsTextStyle(56, bg).fontSize, closeTo(44.8, 0.01));
      expect(IdentityColor.initialsTextStyle(96, bg).fontSize, closeTo(76.8, 0.01));
    });

    test('carries the contrast-picked colour and one weight', () {
      const bg = Color(0xFF3366CC);
      final style = IdentityColor.initialsTextStyle(20, bg);
      expect(style.color, IdentityColor.foregroundOn(bg));
      expect(style.fontWeight, FontWeight.w600);
    });
  });

  group('MediaType', () {
    test('fromMime classifies by prefix', () {
      expect(MediaType.fromMime('image/png'), MediaType.image);
      expect(MediaType.fromMime('video/mp4'), MediaType.video);
      expect(MediaType.fromMime('audio/mpeg'), MediaType.audio);
      expect(MediaType.fromMime('application/pdf'), MediaType.file);
    });

    test('fromName round-trips the enum name, unknown -> file', () {
      for (final t in MediaType.values) {
        expect(MediaType.fromName(t.name), t);
      }
      expect(MediaType.fromName('nonsense'), MediaType.file);
    });
  });

  group('mimeForExtension', () {
    test('maps common extensions, case-insensitively', () {
      expect(mimeForExtension('JPG'), 'image/jpeg');
      expect(mimeForExtension('png'), 'image/png');
      expect(mimeForExtension('mp4'), 'video/mp4');
      expect(mimeForExtension('m4a'), 'audio/mp4');
      expect(mimeForExtension('pdf'), 'application/pdf');
    });

    test('falls back to octet-stream for unknown / null', () {
      expect(mimeForExtension('xyz'), 'application/octet-stream');
      expect(mimeForExtension(null), 'application/octet-stream');
    });
  });

  group('MediaAttachment', () {
    const att = MediaAttachment(
      mediaType: MediaType.video,
      name: 'clip.mp4',
      mime: 'video/mp4',
      size: 2048,
      path: 'chat-1/msg-1/clip.mp4.enc',
      keyB64: 'a2V5',
    );

    test('encode -> tryParse round-trips the descriptor', () {
      final parsed = MediaAttachment.tryParse(att.encode());
      expect(parsed, isNotNull);
      expect(parsed!.mediaType, MediaType.video);
      expect(parsed.name, 'clip.mp4');
      expect(parsed.mime, 'video/mp4');
      expect(parsed.size, 2048);
      expect(parsed.path, att.path);
      expect(parsed.keyB64, att.keyB64);
    });

    test('tryParse returns null for plain text / non-media JSON', () {
      expect(MediaAttachment.tryParse('just a normal message'), isNull);
      expect(MediaAttachment.tryParse(''), isNull);
      expect(MediaAttachment.tryParse(null), isNull);
      expect(MediaAttachment.tryParse('{"foo":"bar"}'), isNull);
    });

    test('tryParse tolerates malformed JSON that contains the marker', () {
      expect(MediaAttachment.tryParse('${MediaAttachment.marker} {not json'),
          isNull);
    });
  });

  group('FileTypeVisual', () {
    FileTypeVisual visualFor(String name, String mime) => FileTypeVisual.of(
          MediaAttachment(
            mediaType: MediaType.file,
            name: name,
            mime: mime,
            size: 1,
            path: 'p',
            keyB64: 'k',
          ),
        );

    test('PDF by mime and by extension', () {
      expect(visualFor('x.pdf', 'application/octet-stream').label, 'PDF');
      expect(visualFor('x', 'application/pdf').label, 'PDF');
      expect(visualFor('x.pdf', 'application/pdf').icon, Icons.picture_as_pdf);
    });

    test('documents / spreadsheets / presentations / archives / code / text', () {
      expect(visualFor('a.docx', 'm').label, 'Document');
      expect(visualFor('a.xlsx', 'm').label, 'Spreadsheet');
      expect(visualFor('a.pptx', 'm').label, 'Presentation');
      expect(visualFor('a.zip', 'm').label, 'Archive');
      expect(visualFor('a.dart', 'm').label, 'Code');
      expect(visualFor('a.txt', 'text/plain').label, 'Text');
    });

    test('unknown extension falls back to the uppercased extension', () {
      expect(visualFor('a.heic', 'application/octet-stream').label, 'HEIC');
      expect(visualFor('noext', 'application/octet-stream').label, 'File');
    });
  });
}
