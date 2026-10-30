// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// CHAT-42: a scanned QR code turned a contact green without checking the key
// against anything, and names could hide characters that look like nothing.

import 'package:chattr/features/identity/qr_pin_rule.dart';
import 'package:chattr/features/profile/username_rules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('QR-Code verifiziert nur, was zusammenpasst', () {
    test('Code = veröffentlicht: verifiziert, auch über einen alten Pin', () {
      expect(decideQrPin(scanned: 'k1', published: 'k1', pinned: 'k0'),
          QrPinDecision.pinVerified);
    });

    test('Code ≠ veröffentlicht: Warnung, nichts geändert', () {
      expect(decideQrPin(scanned: 'k1', published: 'k2', pinned: null),
          QrPinDecision.mismatch);
    });

    test('offline: nur ohne oder mit gleichem Pin', () {
      expect(decideQrPin(scanned: 'k1', published: null, pinned: null),
          QrPinDecision.pinVerified);
      expect(decideQrPin(scanned: 'k1', published: null, pinned: 'k1'),
          QrPinDecision.pinVerified);
      expect(decideQrPin(scanned: 'k1', published: null, pinned: 'k0'),
          QrPinDecision.mismatch,
          reason: 'ein bestehender Pin wird nie still überschrieben');
    });
  });

  group('Namen ohne unsichtbare Zeichen', () {
    test('normale Namen gehen', () {
      expect(isValidUsername('Gerre'), isTrue);
      expect(isValidUsername('Zoë 🦊'), isTrue);
      expect(isValidUsername('مریم'), isTrue, reason: 'Rechts-nach-links-Schrift ist kein Steuerzeichen');
    });

    test('Nullbreite und Richtungsumkehr nicht', () {
      expect(isValidUsername('b​ob'), isFalse);
      expect(isValidUsername('gerry‮yrreg'), isFalse);
      expect(isValidUsername('al\uFEFFice'), isFalse,
          reason: 'am Rand nimmt trim() es weg, in der Mitte nicht');
      expect(isValidUsername('x⁦y'), isFalse);
    });
  });
}
