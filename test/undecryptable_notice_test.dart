// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// A message this device cannot open used to vanish into the log. Now it is
// stored as a notice and shown as a card. These tests pin the two rules that
// decide whether that is safe: a notice must never overwrite a message the
// device already opened, and only a missing one-time key (which never gets
// better) may acknowledge the message and stop the retries.

import 'package:chattr/core/crypto/envelope_version.dart';
import 'package:chattr/core/crypto/undecryptable_notice.dart';
import 'package:chattr/features/messages/message_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UndecryptableNotice', () {
    test('übersteht encode und tryParse mit beiden Gründen', () {
      for (final reason in [UndecryptableNotice.prekey, UndecryptableNotice.keys]) {
        final parsed =
            UndecryptableNotice.tryParse(UndecryptableNotice(reason).encode());
        expect(parsed, isNotNull);
        expect(parsed!.reason, reason);
      }
    });

    test('gewöhnlicher Text ist kein Hinweis', () {
      expect(UndecryptableNotice.tryParse('hallo'), isNull);
      expect(UndecryptableNotice.tryParse(null), isNull);
      expect(UndecryptableNotice.tryParse(''), isNull);
    });

    test('Text, der den Schlüssel nur erwähnt, ist kein Hinweis', () {
      expect(UndecryptableNotice.tryParse('schau: _chattr_undecryptable'), isNull);
      expect(
        UndecryptableNotice.tryParse('{"_chattr_undecryptable":null}'),
        isNull,
      );
    });

    test('fehlender Grund fällt auf „keys" zurück', () {
      expect(
        UndecryptableNotice.tryParse('{"_chattr_undecryptable":1}')!.reason,
        UndecryptableNotice.keys,
      );
    });
  });

  group('undecryptableAction', () {
    const real = 'Wir sehen uns um acht';

    test('fehlender Einmalschlüssel ohne Inhalt: ablegen und quittieren', () {
      expect(
        undecryptableAction(definitive: true, existingContent: null),
        UndecryptableAction.storeAndAcknowledge,
      );
    });

    test('anderer Fehler ohne Inhalt: ablegen, Serverkopie bleibt', () {
      expect(
        undecryptableAction(definitive: false, existingContent: null),
        UndecryptableAction.storeOnly,
      );
    });

    test('echter Inhalt wird nie überschrieben', () {
      // Der Fall „Duplikat einer schon geöffneten Nachricht": Der private Teil
      // des Einmalschlüssels ist nach dem ersten Öffnen gelöscht, ein zweiter
      // Abholversuch scheitert also zwangsläufig.
      expect(
        undecryptableAction(definitive: true, existingContent: real),
        UndecryptableAction.acknowledgeOnly,
      );
      expect(
        undecryptableAction(definitive: false, existingContent: real),
        UndecryptableAction.ignore,
      );
    });

    test('ein früherer Hinweis zählt nicht als Inhalt', () {
      final earlier = const UndecryptableNotice(UndecryptableNotice.keys).encode();
      expect(
        undecryptableAction(definitive: true, existingContent: earlier),
        UndecryptableAction.storeAndAcknowledge,
      );
      expect(
        undecryptableAction(definitive: false, existingContent: earlier),
        UndecryptableAction.storeOnly,
      );
    });

    test('auch der Platzhalter „Neuere App-Version nötig" zählt nicht als Inhalt', () {
      final unsupported = const UnsupportedEnvelopeNotice(9).encode();
      expect(
        undecryptableAction(definitive: false, existingContent: unsupported),
        UndecryptableAction.storeOnly,
      );
    });

    test('leerer Inhalt zählt nicht als Inhalt', () {
      expect(
        undecryptableAction(definitive: true, existingContent: ''),
        UndecryptableAction.storeAndAcknowledge,
      );
    });
  });

  group('Hinweis anstelle einer Systemnachricht', () {
    // 2026-10-24 am Galaxy: Ließ sich eine Systemnachricht („… hat neue
    // Schlüssel erzeugt“) nicht öffnen, ging der Hinweis durch den Formatierer
    // für Systemnachrichten. Der machte aus JSON Darts Map-Schreibweise, und im
    // Chat stand „{_chattr_undecryptable: 1, r: keys}“ statt der Karte.
    test('bleibt JSON und wird als Hinweis erkannt', () {
      final notice =
          const UndecryptableNotice(UndecryptableNotice.keys).encode();
      final m = SystemMessage(
        id: 'm',
        chatId: 'c',
        createdAt: DateTime.utc(2026, 10, 12),
        recipientId: 'r',
      ).withDecryptedContent(notice);
      expect(m.decryptedContent, notice);
      expect(UndecryptableNotice.tryParse(m.decryptedContent)?.reason,
          UndecryptableNotice.keys);
    });

    test('schon so gespeicherte Zeilen werden wieder erkannt', () {
      expect(
        UndecryptableNotice.tryParse('{_chattr_undecryptable: 1, r: prekey}')
            ?.reason,
        UndecryptableNotice.prekey,
      );
      expect(
        UnsupportedEnvelopeNotice.tryParse('{_chattr_unsupported: 1, v: 7}')
            ?.version,
        7,
      );
      expect(UndecryptableNotice.tryParse('{_chattr_undecryptable: kaputt}'),
          isNull);
    });

    test('eine gewöhnliche Systemnachricht wird weiter gelesen', () {
      final m = SystemMessage(
        id: 'm',
        chatId: 'c',
        createdAt: DateTime.utc(2026, 10, 12),
        recipientId: 'r',
      ).withDecryptedContent('{"action":"keys_rotated","subject_id":"u"}');
      expect(m.action, 'keys_rotated');
      expect(m.subjectId, 'u');
    });
  });
}
