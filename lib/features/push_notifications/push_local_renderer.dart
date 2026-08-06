// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'push_render_cache.dart';

/// The text of a notification the device built for itself.
class RenderedPush {
  const RenderedPush({
    required this.title,
    required this.body,
    required this.chatId,
  });

  final String title;
  final String body;

  /// Groups the notification: all messages of one chat collapse into a single
  /// entry instead of stacking, the way they did when Android rendered them
  /// from the server's payload. Null when the push carries no chat.
  final String? chatId;

  /// Stable per-chat notification id, so a second message REPLACES the first
  /// rather than piling up. Masked to stay positive — Android ids are ints and
  /// a negative one is silently dropped by some OEM launchers.
  int get notificationId => (chatId ?? 'chattr').hashCode & 0x7fffffff;
}

/// Turns the id-only push payload back into readable text.
///
/// Deliberately pure: no plugins, no I/O, no platform. The background isolate
/// is a bad place to debug, so everything that can be decided without the
/// system lives here where a unit test can reach it.
///
/// Every unknown maps to a generic wording rather than an error. A push whose
/// sender is not in the cache still has to produce *a* notification — the
/// alternative is silence, which is indistinguishable from a broken push
/// pipeline and is the failure this whole feature must not introduce.
RenderedPush? renderPush(
  Map<String, dynamic> data, {
  required Map<String, String> names,
  required PushTemplates templates,
}) {
  String? str(String key) {
    final value = data[key];
    if (value is String && value.isNotEmpty) return value;
    return null;
  }

  final type = str('type');
  final chatId = str('chat_id');
  final chatName = (chatId == null || (names[chatId] ?? '').isEmpty)
      ? null
      : names[chatId];

  /// A cached name, or null when it is missing OR empty. The empty case is not
  /// theoretical: the cache is a merge of several sources, and one of them can
  /// write "" for a profile that has no username yet. Treating that as a name
  /// produced " hat ein Foto gesendet" — leading gap, no sender. Swift and JS
  /// both got this right (JS by accident: "" is falsy); Dart was the outlier.
  String? namedOrNull(String? id) {
    final resolved = id == null ? null : names[id];
    return (resolved == null || resolved.isEmpty) ? null : resolved;
  }

  String nameOf(String? id) {
    final resolved = id == null ? null : names[id];
    return (resolved == null || resolved.isEmpty)
        ? templates.someone
        : resolved;
  }

  String fill(String template, {String? user, String? chat}) {
    var out = template;
    if (user != null) out = out.replaceAll('{user}', user);
    if (chat != null) out = out.replaceAll('{chat}', chat);
    return out;
  }

  switch (type) {
    case 'new_message':
      final sender = namedOrNull(str('sender_id'));
      // `media_kind` is present only when the server had a category AND this
      // recipient allows it to travel (00067). Absent → the wording that
      // shipped before, which is why every unknown value falls through to it
      // rather than inventing a sentence.
      final mediaTemplate = switch (str('media_kind')) {
        'image' => templates.newMessageImage,
        'video' => templates.newMessageVideo,
        'audio' => templates.newMessageAudio,
        'other' => templates.newMessageFile,
        _ => null,
      };
      return RenderedPush(
        title: chatName ?? templates.chatFallback,
        // Naming an unknown sender "Someone" reads worse than not naming one at
        // all, so the unknown case gets its own sentence — and that sentence
        // stays generic even for media, because "sent a photo" without a sender
        // reads like a fragment.
        body: sender == null
            ? templates.newMessageUnknown
            : fill(mediaTemplate ?? templates.newMessage, user: sender),
        chatId: chatId,
      );

    case 'reaction':
      final sender = namedOrNull(str('sender_id'));
      return RenderedPush(
        title: chatName ?? templates.chatFallback,
        body: sender == null
            ? templates.reactionUnknown
            : fill(templates.reaction, user: sender),
        chatId: chatId,
      );

    case 'member_request':
      return RenderedPush(
        title: templates.memberRequestTitle,
        body: fill(
          templates.memberRequestBody,
          user: nameOf(str('requester_id')),
          chat: chatName ?? templates.chatFallback,
        ),
        chatId: chatId,
      );

    default:
      // An unknown type means the server got ahead of this build. Showing a
      // bare "Chattr" would be worse than staying quiet: the app will pick the
      // event up through the normal realtime path once it is opened, and a
      // notification with no meaning trains people to ignore them.
      //
      // PLATTFORM-UNTERSCHIED, bewusst: Android und Web können hier wirklich
      // schweigen. iOS kann es NICHT — eine Notification Service Extension darf
      // eine Benachrichtigung mit alert-Block nur verändern, nicht
      // unterdrücken. Dort bleibt deshalb der Platzhalter des Servers stehen
      // ("Chattr" / "Neue Nachricht"): generisch, aber nicht falsch. Genau
      // dafür ist der Platzhalter ein vollständiger Satz und kein Fülltext.
      // (Hinweis von mac-claude beim Bau der Extension, 2026-08-05.)
      return null;
  }
}
