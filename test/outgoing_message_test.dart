// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chattr/core/models/optional.dart';
import 'package:chattr/core/security/keys_not_ready_exception.dart';
import 'package:chattr/features/messages/message_model.dart';
import 'package:chattr/features/messages/outgoing_message.dart';
import 'package:chatview/chatview.dart' as chatview;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' show ClientException;
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

Message _own({LocalSendState? state, SendFailure? failure}) => Message(
      id: 'm1',
      chatId: 'c1',
      senderId: 'me',
      recipientId: 'me',
      createdAt: DateTime.utc(2026, 10, 30, 1),
      decryptedContent: 'Hallo',
      receivedAt: state == null ? {'peer': null} : const {},
      readAt: state == null ? {'peer': null} : const {},
      sendState: state,
      sendFailure: failure,
    );

void main() {
  group('Sendestatus im Modell (CHAT-66)', () {
    test('ein fehlgeschlagener Stand übersteht das Speichern', () {
      final failed =
          _own(state: LocalSendState.failed, failure: SendFailure.network);
      final back = Message.fromJson(failed.toJson());
      expect(back.sendState, LocalSendState.failed);
      expect(back.sendFailure, SendFailure.network);
      expect(back.isUnsent, isTrue);
    });

    test('ältere Zeilen ohne das Feld gelten als gesendet', () {
      final json = _own().toJson()
        ..remove('send_state')
        ..remove('send_failure');
      final back = Message.fromJson(json);
      expect(back.sendState, isNull);
      expect(back.isUnsent, isFalse);
    });

    test('ein unbekannter Wert (neuere App) liest sich als gesendet, nicht als Absturz',
        () {
      final json = _own().toJson()..['send_state'] = 'queued_for_later';
      expect(Message.fromJson(json).sendState, isNull);
    });

    test('unterwegs: Uhr, und der Zustand reist in update mit', () {
      final m = _own(state: LocalSendState.pending).toChatViewMessage();
      expect(m.status, chatview.MessageStatus.pending);
      expect(sendStateOf(m), LocalSendState.pending);
    });

    test('fehlgeschlagen: Grund kommt bei der Blase an', () {
      final m = _own(state: LocalSendState.failed, failure: SendFailure.rejected)
          .toChatViewMessage();
      expect(m.status, chatview.MessageStatus.pending);
      expect(sendStateOf(m), LocalSendState.failed);
      expect(sendFailureOf(m), SendFailure.rejected);
    });

    test('gesendet: ein Haken, keine Sendedaten im update', () {
      final m = _own().toChatViewMessage();
      expect(m.status, chatview.MessageStatus.undelivered);
      expect(sendStateOf(m), isNull);
      expect(m.update, isNull);
    });

    test('copyWith räumt den Zustand ab und übernimmt expiresAt', () {
      final expires = DateTime.utc(2026, 10, 31);
      final sent = _own(state: LocalSendState.pending).copyWith(
        sendState: Optional.empty(),
        expiresAt: Optional(expires),
      );
      expect(sent.sendState, isNull);
      expect(sent.expiresAt, expires);
      expect(sent.copyWith(isFavorite: true).expiresAt, expires,
          reason: 'vorher ging expiresAt bei jedem copyWith verloren');
    });

    test('Zustandswechsel ändert den Hash (sonst bleibt die Blase stehen)', () {
      final pending = _own(state: LocalSendState.pending);
      final failed = pending.copyWith(
        sendState: Optional(LocalSendState.failed),
        sendFailure: Optional(SendFailure.network),
      );
      expect(failed == pending, isFalse);
      expect(failed.hashCode == pending.hashCode, isFalse);
    });
  });

  group('Fehler einordnen', () {
    test('kein Netz', () {
      expect(classifySendFailure(ClientException('Failed host lookup')),
          SendFailure.network);
    });

    test('Schlüssel des Gegenübers fehlen', () {
      expect(classifySendFailure(const KeysNotReadyException()),
          SendFailure.keysNotReady);
    });

    test('Server sagt nein', () {
      expect(
        classifySendFailure(
            const PostgrestException(message: 'denied', code: '42501')),
        SendFailure.rejected,
      );
    });

    test('23505 heißt: ein früherer Versuch ist durchgegangen', () {
      expect(
        isAlreadyOnServer(
            const PostgrestException(message: 'duplicate key', code: '23505')),
        isTrue,
      );
      expect(
        isAlreadyOnServer(
            const PostgrestException(message: 'denied', code: '42501')),
        isFalse,
      );
      expect(isAlreadyOnServer(ClientException('x')), isFalse);
    });
  });
}
