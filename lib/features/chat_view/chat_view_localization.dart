// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:ui' show Locale;

import 'package:chatview/chatview.dart' as chatview;

/// German strings for chatview's package-internal labels (date separators
/// "Today"/"Yesterday", reply headers, typing indicator, edited label, …).
/// Without this the package always renders its English defaults regardless
/// of the app locale.
const chatview.ChatViewLocale _de = chatview.ChatViewLocale(
  today: 'Heute',
  yesterday: 'Gestern',
  repliedToYou: 'Hat dir geantwortet',
  // chatview composes two different strings from the shared `you` string:
  // "$replyTo $name" (compose box, needs accusative after "an") and
  // "$repliedBy $name" (quote label on a sent reply). Using "an"/"auf" for
  // both (both take accusative) lets `you: 'Dich'` work correctly in either
  // slot instead of only patching it with a colon.
  repliedBy: 'Antwort auf',
  more: 'Mehr',
  unsend: 'Löschen',
  reply: 'Antworten',
  replyTo: 'Antwort an:',
  message: 'Nachricht',
  reactionPopupTitle: 'Halten, um die Reaktion zu verstärken',
  photo: 'Foto',
  send: 'Senden',
  // Accusative, not nominative: composed as "an Dich" / "auf Dich" (see
  // repliedBy above) — the previous 'Du' was only grammatical by accident
  // in the compose-box slot and outright wrong in the quote-label slot.
  you: 'Dich',
  report: 'Melden',
  noMessage: 'Keine Nachrichten',
  somethingWentWrong: 'Etwas ist schiefgelaufen!',
  reload: 'Neu laden',
  search: 'Suchen',
  now: 'Jetzt',
  minAgo: 'Min.',
  voice: 'Sprachnachricht',
  typing: 'schreibt',
  isVerb: '',
  areVerb: '',
  other: 'weitere Person',
  others: 'weitere Personen',
  mute: 'Stummschalten',
  unmute: 'Laut schalten',
  pin: 'Anheften',
  unpin: 'Lösen',
  deleteChat: 'Chat löschen',
  noChats: 'Keine Chats',
  noSearchResults: 'Keine Treffer',
  edit: 'Bearbeiten',
  edited: 'Bearbeitet',
  editing: 'Bearbeiten',
);

bool _deRegistered = false;

/// Points chatview's global string table at the app locale. Call whenever the
/// app (re)builds with a locale — cheap and idempotent.
void syncChatViewLocale(Locale locale) {
  if (locale.languageCode == 'de') {
    if (!_deRegistered) {
      chatview.PackageStrings.addLocaleObject('de', _de);
      _deRegistered = true;
    }
    chatview.PackageStrings.setLocale('de');
  } else {
    chatview.PackageStrings.setLocale('en');
  }
}
