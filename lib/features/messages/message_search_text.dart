// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import '../media/media_attachment.dart';
import 'message_envelopes.dart';

/// The text of a message as a **search** may see it — or `null` when there is
/// none.
///
/// A message body is not always prose. A photo, a shot, a shared place travel as JSON
/// in an ordinary text field; what is rendered from it is a card, what is stored is the
/// string. Whoever searches raw over it gets two faults at once (reported by Gerry,
/// 2026-09-02):
///
/// 1. **Hits that are none.** "jpg", "items", "http" stand in every media envelope.
///    The search found pictures that had nothing to do with what was sought — and with
///    a shot, of all things, the envelope carrying path and media key.
/// 2. **Previews from raw JSON.** The hit list showed `{"_chattr_media":1,…}` instead
///    of a readable sentence.
///
/// The rule is therefore: **a medium is findable only through its caption, and only
/// the caption is displayed.** If it has none, it has no text — then it does not turn
/// up in the search at all. That is no loss: what one would search for in a picture
/// without a caption does not exist; that is what the media tab is for.
///
/// A **shot** never has text, even if its envelope contained some — it can be opened
/// exactly once, and a hit list would be a second way around its promise.
///
/// The same function answers both questions — "is this a hit?" and "what stands in the
/// row?". Separate answers would drift apart sooner or later, and then a hit would
/// stand there without a visible reason.
String? searchableText(String? body) {
  if (body == null) return null;
  final raw = body.trim();
  if (raw.isEmpty) return null;

  // Invitation, place, appointment, shot, placeholder for a too-new message:
  // all cards, no running text.
  if (isEnvelopeMessage(raw)) return null;

  final album = MediaAlbum.tryParse(raw);
  if (album != null) {
    final caption = album.caption?.trim();
    if (caption == null || caption.isEmpty) return null;
    return caption;
  }

  return raw;
}

/// Does [query] match the readable part of [body]?
///
/// The search is deliberately case-blind and looks for a substring, not a whole
/// word — that is how it has always been.
bool matchesSearch(String? body, String query) {
  final text = searchableText(body);
  if (text == null) return false;
  return text.toLowerCase().contains(query);
}
