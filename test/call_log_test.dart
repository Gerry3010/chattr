// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Call entries in the chat: which call leaves which line, and that only a
// missed call counts as unread.

import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/features/calls/call_log.dart';
import 'package:chattr/features/calls/call_rules.dart';
import 'package:chattr/features/messages/message_model.dart';
import 'package:chattr/features/messages/messages_local_repository.dart';

void main() {
  final end = DateTime(2026, 10, 5, 21, 0, 0);
  CallLogEntry? entry(bool incoming, CallEndReason r, {int? talked}) =>
      callLogEntryFor(
        incoming: incoming,
        reason: r,
        connectedAt:
            talked == null ? null : end.subtract(Duration(seconds: talked)),
        endedAt: end,
      );

  group('Welcher Anruf welchen Eintrag hinterlässt', () {
    test('ausgehend, gesprochen: Dauer', () {
      final e = entry(false, CallEndReason.hangup, talked: 133)!;
      expect(e.action, callOutgoing);
      expect(e.detail, '133');
    });

    test('ausgehend, nicht angenommen – egal warum', () {
      for (final r in [
        CallEndReason.noAnswer,
        CallEndReason.declined,
        CallEndReason.cancelled,
        CallEndReason.busy,
        CallEndReason.failed,
      ]) {
        final e = entry(false, r)!;
        expect(e.action, callOutgoing, reason: '$r');
        expect(e.detail, '0', reason: '$r');
      }
    });

    test('eingehend, gesprochen: Dauer', () {
      final e = entry(true, CallEndReason.remoteHangup, talked: 65)!;
      expect(e.action, callIncoming);
      expect(e.detail, '65');
    });

    test('eingehend, nicht angenommen: verpasst', () {
      expect(entry(true, CallEndReason.missed)!.action, callMissed);
      expect(entry(true, CallEndReason.failed)!.action, callMissed);
    });

    test('eingehend, selbst abgelehnt: abgelehnt, nicht verpasst', () {
      expect(entry(true, CallEndReason.declined)!.action, callDeclined);
    });

    test('was nie geklingelt hat, hinterlässt nichts', () {
      for (final r in [
        CallEndReason.unavailable,
        CallEndReason.keyChanged,
        CallEndReason.micDenied,
        CallEndReason.relayUnavailable,
      ]) {
        expect(entry(false, r), isNull, reason: '$r');
      }
    });
  });

  test('Gesprächsdauer lesbar', () {
    expect(formatTalkTime(0), '0:00');
    expect(formatTalkTime(133), '2:13');
    expect(formatTalkTime(3725), '1:02:05');
  });

  group('Ungelesen', () {
    SystemMessage call(String action) => SystemMessage(
          id: 'x',
          chatId: 'c',
          createdAt: end,
          recipientId: 'me',
          action: action,
          detail: '0',
        );

    test('nur ein verpasster Anruf zählt als ungelesen', () {
      expect(isIncomingMessage(call(callMissed), 'me'), isTrue);
      expect(isIncomingMessage(call(callOutgoing), 'me'), isFalse);
      expect(isIncomingMessage(call(callIncoming), 'me'), isFalse);
      expect(isIncomingMessage(call(callDeclined), 'me'), isFalse);
    });

    test('andere Systemnachrichten bleiben, wie sie waren', () {
      expect(isIncomingMessage(call('joined'), 'me'), isTrue);
    });
  });
}
