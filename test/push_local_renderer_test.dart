// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chattr/features/push_notifications/push_local_renderer.dart';
import 'package:chattr/features/push_notifications/push_render_cache.dart';
import 'package:flutter_test/flutter_test.dart';

/// Since "Push ohne Klartext" (migration 00065) the server sends only ids, and
/// the device turns them back into words — in a background isolate, where a
/// mistake surfaces as "no notification" and nothing else. Hence these tests.
void main() {
  const templates = PushTemplates(
    newMessage: 'Neue Nachricht von {user}',
    newMessageUnknown: 'Neue Nachricht',
    newMessageImage: '{user} hat ein Foto gesendet',
    newMessageVideo: '{user} hat ein Video gesendet',
    newMessageAudio: '{user} hat eine Audiodatei gesendet',
    newMessageFile: '{user} hat eine Datei gesendet',
    reaction: '{user} hat auf deine Nachricht reagiert',
    reactionUnknown: 'Jemand hat auf deine Nachricht reagiert',
    memberRequestTitle: 'Neue Beitritts-Anfrage',
    memberRequestBody: '{user} möchte {chat} beitreten',
    chatFallback: 'Chattr',
    someone: 'Jemand',
  );

  const names = {
    'chat-1': 'Familie',
    'user-1': 'Bob',
    'user-2': 'Alice',
  };

  RenderedPush? render(Map<String, dynamic> data) =>
      renderPush(data, names: names, templates: templates);

  group('new_message', () {
    test('resolves chat and sender from the cache', () {
      final push = render({
        'type': 'new_message',
        'chat_id': 'chat-1',
        'message_id': 'm1',
        'sender_id': 'user-1',
      })!;

      expect(push.title, 'Familie');
      expect(push.body, 'Neue Nachricht von Bob');
      expect(push.chatId, 'chat-1');
    });

    test('an unknown sender gets its own wording, not "Jemand"', () {
      // "Neue Nachricht von Jemand" reads like a bug; the unknown case has a
      // sentence of its own.
      final push = render({
        'type': 'new_message',
        'chat_id': 'chat-1',
        'sender_id': 'user-unknown',
      })!;

      expect(push.body, 'Neue Nachricht');
      expect(push.body, isNot(contains('Jemand')));
    });

    test('an unknown chat still produces a notification', () {
      // The whole point of the fallbacks: a cache miss must never mean silence.
      final push = render({
        'type': 'new_message',
        'chat_id': 'chat-unknown',
        'sender_id': 'user-1',
      })!;

      expect(push.title, 'Chattr');
      expect(push.body, 'Neue Nachricht von Bob');
    });

    test('survives a payload with nothing but its type', () {
      final push = render({'type': 'new_message'})!;
      expect(push.title, 'Chattr');
      expect(push.body, 'Neue Nachricht');
      expect(push.chatId, isNull);
    });
  });

  group('reaction', () {
    test('names the reactor', () {
      final push = render({
        'type': 'reaction',
        'chat_id': 'chat-1',
        'sender_id': 'user-2',
      })!;

      expect(push.title, 'Familie');
      expect(push.body, 'Alice hat auf deine Nachricht reagiert');
    });

    test('falls back when the reactor is unknown', () {
      final push = render({'type': 'reaction', 'chat_id': 'chat-1'})!;
      expect(push.body, 'Jemand hat auf deine Nachricht reagiert');
    });
  });

  group('member_request', () {
    test('fills both placeholders', () {
      final push = render({
        'type': 'member_request',
        'chat_id': 'chat-1',
        'requester_id': 'user-2',
      })!;

      expect(push.title, 'Neue Beitritts-Anfrage');
      expect(push.body, 'Alice möchte Familie beitreten');
    });

    test('an unknown requester is "Jemand", the chat still resolves', () {
      final push = render({
        'type': 'member_request',
        'chat_id': 'chat-1',
        'requester_id': 'nobody',
      })!;

      expect(push.body, 'Jemand möchte Familie beitreten');
    });
  });

  group('robustness', () {
    test('an unknown type renders nothing at all', () {
      // A meaningless "Chattr" notification is worse than none: it trains
      // people to ignore them, and the app picks the event up over realtime
      // as soon as it is opened.
      expect(render({'type': 'some_future_type', 'chat_id': 'chat-1'}), isNull);
      expect(render({'chat_id': 'chat-1'}), isNull);
      expect(render(const {}), isNull);
    });

    test('non-string payload values are ignored, not crashed on', () {
      // FCM data is string-typed, but the map arrives as Map<String, dynamic>
      // and this runs where an exception equals a lost notification.
      final push = render({
        'type': 'new_message',
        'chat_id': 42,
        'sender_id': null,
      })!;

      expect(push.title, 'Chattr');
      expect(push.chatId, isNull);
    });

    test('the notification id is stable per chat and never negative', () {
      final a = render({'type': 'new_message', 'chat_id': 'chat-1'})!;
      final b = render({'type': 'reaction', 'chat_id': 'chat-1'})!;
      final other = render({'type': 'new_message', 'chat_id': 'chat-2'})!;

      // Same chat → same id, so a second message REPLACES the first instead
      // of stacking.
      expect(a.notificationId, b.notificationId);
      expect(a.notificationId, isNot(other.notificationId));
      // Some OEM launchers silently drop a negative id.
      expect(a.notificationId, greaterThanOrEqualTo(0));
      expect(other.notificationId, greaterThanOrEqualTo(0));
    });
  });

  group('PushTemplates', () {
    test('round-trips through JSON', () {
      final restored = PushTemplates.fromJson(templates.toJson());
      expect(restored.newMessage, templates.newMessage);
      expect(restored.memberRequestBody, templates.memberRequestBody);
      expect(restored.someone, templates.someone);
    });

    test('missing or empty entries fall back to the English defaults', () {
      // A half-written cache must degrade to readable English, not to blanks.
      final partial = PushTemplates.fromJson({
        'new_message': 'Von {user}',
        'reaction': '',
      });

      expect(partial.newMessage, 'Von {user}');
      expect(partial.reaction, PushTemplates.fallback.reaction);
      expect(partial.someone, PushTemplates.fallback.someone);
    });

    test('nothing cached at all still yields usable wording', () {
      final push = renderPush(
        {'type': 'new_message', 'chat_id': 'c', 'sender_id': 'u'},
        names: const {},
        templates: PushTemplates.fromJson(const {}),
      )!;

      expect(push.title, 'Chattr');
      expect(push.body, 'New message');
    });
  });

  group('media kind (00067)', () {
    test('a known kind changes the sentence, the title stays the chat', () {
      for (final (kind, expected) in [
        ('image', 'Anna sent a photo'),
        ('video', 'Anna sent a video'),
        ('audio', 'Anna sent an audio file'),
        ('other', 'Anna sent a file'),
      ]) {
        final r = renderPush(
          {'type': 'new_message', 'chat_id': 'c1', 'sender_id': 'u1',
           'media_kind': kind},
          names: {'c1': 'Kochgruppe', 'u1': 'Anna'},
          templates: PushTemplates.fallback,
        );
        expect(r!.body, expected, reason: kind);
        expect(r.title, 'Kochgruppe');
      }
    });

    test('no kind, or one this build does not know, keeps the old wording', () {
      for (final data in [
        {'type': 'new_message', 'chat_id': 'c1', 'sender_id': 'u1'},
        {'type': 'new_message', 'chat_id': 'c1', 'sender_id': 'u1',
         'media_kind': 'hologram'},
        {'type': 'new_message', 'chat_id': 'c1', 'sender_id': 'u1',
         'media_kind': ''},
      ]) {
        final r = renderPush(data,
            names: {'c1': 'Kochgruppe', 'u1': 'Anna'},
            templates: PushTemplates.fallback);
        expect(r!.body, 'New message from Anna', reason: '$data');
      }
    });

    test('an unknown sender stays generic even with a kind', () {
      // "sent a photo" with nobody in front of it reads like a fragment.
      final r = renderPush(
        {'type': 'new_message', 'chat_id': 'c1', 'sender_id': 'ghost',
         'media_kind': 'image'},
        names: const {},
        templates: PushTemplates.fallback,
      );
      expect(r!.body, 'New message');
    });

    test('the templates survive a cache round-trip', () {
      final back = PushTemplates.fromJson(PushTemplates.fallback.toJson());
      expect(back.newMessageImage, PushTemplates.fallback.newMessageImage);
      expect(back.newMessageFile, PushTemplates.fallback.newMessageFile);
    });
  });

  group('leere Namen im Cache', () {
    // Beim Gegenlesen von mac-claudes Swift-Fassung gefunden: er prüft
    // !isEmpty, Dart prüfte nur auf null. Ein leerer Eintrag ergab damit
    // " hat ein Foto gesendet" — führende Lücke, kein Absender.
    test('ein leerer Absendername zählt als unbekannt', () {
      final r = renderPush(
        {'type': 'new_message', 'chat_id': 'c1', 'sender_id': 'u1',
         'media_kind': 'image'},
        names: {'c1': 'Kochgruppe', 'u1': ''},
        templates: PushTemplates.fallback,
      );
      expect(r!.body, 'New message');
      expect(r.body, isNot(startsWith(' ')));
    });

    test('ein leerer Chatname fällt auf den Standardtitel zurück', () {
      final r = renderPush(
        {'type': 'new_message', 'chat_id': 'c1', 'sender_id': 'u1'},
        names: {'c1': '', 'u1': 'Anna'},
        templates: PushTemplates.fallback,
      );
      expect(r!.title, 'Chattr');
    });

    test('auch bei Reaktionen', () {
      final r = renderPush(
        {'type': 'reaction', 'chat_id': 'c1', 'sender_id': 'u1'},
        names: {'c1': 'Kochgruppe', 'u1': ''},
        templates: PushTemplates.fallback,
      );
      expect(r!.body, 'Someone reacted to your message');
    });
  });
}
