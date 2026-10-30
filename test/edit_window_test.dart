// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Edit window: a day after sending while unread, ten minutes after the
// first read, never past the day. Mirrors edit_message (00090).

import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/features/messages/edit_window.dart';

void main() {
  final sent = DateTime.utc(2026, 10, 5, 12);

  test('ungelesen: einen Tag lang', () {
    expect(canEditMessage(sentAt: sent, now: sent.add(const Duration(hours: 23))), isTrue);
    expect(canEditMessage(sentAt: sent, now: sent.add(const Duration(hours: 25))), isFalse);
  });

  test('gelesen: zehn Minuten ab dem ersten Lesen', () {
    final read = sent.add(const Duration(hours: 2));
    expect(
        canEditMessage(
            sentAt: sent,
            firstReadAt: read,
            now: read.add(const Duration(minutes: 9))),
        isTrue);
    expect(
        canEditMessage(
            sentAt: sent,
            firstReadAt: read,
            now: read.add(const Duration(minutes: 11))),
        isFalse);
  });

  test('spät gelesen verlängert nicht über den Tag hinaus', () {
    final read = sent.add(const Duration(hours: 23, minutes: 58));
    expect(editDeadline(sentAt: sent, firstReadAt: read),
        sent.add(const Duration(hours: 24)));
  });

  test('in der Gruppe zählt der erste Leser', () {
    final first = sent.add(const Duration(minutes: 30));
    expect(
        firstReadOf({
          'a': null,
          'b': first.add(const Duration(minutes: 40)),
          'c': first,
        }),
        first);
    expect(firstReadOf({'a': null}), isNull);
  });

  test('Uhrversatz sperrt den Absender nie zu früh aus', () {
    expect(
        canEditMessage(
            sentAt: sent, now: sent.subtract(const Duration(minutes: 3))),
        isTrue);
  });
}
