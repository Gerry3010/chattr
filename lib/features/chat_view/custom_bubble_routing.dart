// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import '../../core/crypto/envelope_version.dart';
import '../../core/crypto/undecryptable_notice.dart';
import '../invites/invite_envelope.dart';
import '../media/media_attachment.dart';
import '../media/shot_envelope.dart';
import '../mentions/mention_utils.dart';
import '../messages/message_links.dart';
import '../messages/message_markdown.dart';
import '../places/place_envelope.dart';

/// Whether a user message's plaintext needs the app's own bubble
/// (`MessageType.custom`, drawn by `_customMessageBuilder` in
/// chat_view_body.dart) instead of chatview's plain text bubble.
///
/// Anything structured that falls through to the text bubble shows up as its
/// raw JSON. Every kind the custom builder draws therefore has to be listed
/// here, or the builder's own check for it never runs.
bool rendersInCustomBubble(String? body, Set<String> mentionUsernames) {
  final text = body ?? '';
  return
      // Stand-ins for a message this build cannot show: from a newer app
      // version, or not decryptable on this device. Not content, so they
      // come first. Without them here, every 1:1 message that failed to
      // decrypt read `{"_chattr_undecryptable":1,...}` (CHAT-8 test,
      // 2026-10-30); system messages were never affected.
      UnsupportedEnvelopeNotice.tryParse(body) != null ||
          UndecryptableNotice.tryParse(body) != null ||
          // A shot (1.27) has a bubble of its own, and the order in the
          // builder keeps it from passing as an ordinary photo.
          ShotEnvelope.tryParse(body) != null ||
          // Media attachments: image inline / file card.
          MediaAttachment.tryParse(body) != null ||
          // Group invitations render as a join card (InviteMessageCard).
          InviteEnvelope.tryParse(body) != null ||
          // Shared marker / calendar entry (#70).
          LocationEnvelope.tryParse(body) != null ||
          EventEnvelope.tryParse(body) != null ||
          // Markdown (MarkdownMessageBubble), so `[text](url)` renders as a
          // formatted link rather than a preview card.
          hasMarkdown(text) ||
          // Links and bare e-mail addresses (LinkMessageBubble): chatview's
          // own text bubble hard-wires the AnyLinkPreview card, which rendered
          // as a big empty white block, and does not link e-mails at all.
          extractUrls(body).isNotEmpty ||
          extractEmails(body).isNotEmpty ||
          // An @-mention is highlighted only by MarkdownMessageBubble.
          hasAnyMention(text, mentionUsernames);
}
