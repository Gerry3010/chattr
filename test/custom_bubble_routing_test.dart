// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chattr/core/crypto/envelope_version.dart';
import 'package:chattr/core/crypto/undecryptable_notice.dart';
import 'package:chattr/features/chat_view/custom_bubble_routing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('rendersInCustomBubble', () {
    test('eine nicht lesbare Nachricht bekommt die Karte, nicht ihr JSON', () {
      // Exactly the body from the CHAT-8 test on the iOS simulator.
      expect(
        rendersInCustomBubble(
          const UndecryptableNotice(UndecryptableNotice.prekey).encode(),
          const {},
        ),
        isTrue,
      );
      expect(
        rendersInCustomBubble(
          const UndecryptableNotice(UndecryptableNotice.keys).encode(),
          const {},
        ),
        isTrue,
      );
    });

    test('eine Nachricht von einer neueren App-Version ebenso', () {
      expect(
        rendersInCustomBubble(const UnsupportedEnvelopeNotice(7).encode(), {}),
        isTrue,
      );
    });

    test('auch die alte Map-Schreibweise der Platzhalter', () {
      expect(
        rendersInCustomBubble('{_chattr_undecryptable: 1, r: keys}', {}),
        isTrue,
      );
      expect(
        rendersInCustomBubble('{_chattr_unsupported: 1, v: 7}', {}),
        isTrue,
      );
    });

    test('gewöhnlicher Text bleibt in der Textblase', () {
      expect(rendersInCustomBubble('Hallo, wie geht’s?', {}), isFalse);
      expect(rendersInCustomBubble(null, {}), isFalse);
      expect(rendersInCustomBubble('', {}), isFalse);
    });

    test('Links, E-Mail-Adressen und Erwähnungen wie bisher', () {
      expect(rendersInCustomBubble('schau https://chattr.at an', {}), isTrue);
      expect(rendersInCustomBubble('schreib an a@b.at', {}), isTrue);
      expect(rendersInCustomBubble('@bob kommst du?', {'bob'}), isTrue);
      expect(rendersInCustomBubble('**fett**', {}), isTrue);
    });
  });
}
