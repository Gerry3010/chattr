// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

/// What a double tap on a bubble does (CHAT-15, Gerry 2026-10-28).
enum DoubleTapAction { react, copyMode, none }

/// The rule, pure: media gets the double-tap reaction, readable text opens
/// copy mode, everything else (notices, envelopes such as places or
/// invitations, undecrypted placeholders, a chat one may not write in) nothing.
DoubleTapAction doubleTapActionFor({
  required bool isSystem,
  required bool canInteract,
  required bool isMedia,
  required bool isText,
  required bool isDecrypted,
  required bool isEnvelope,
}) {
  if (isSystem || !canInteract) return DoubleTapAction.none;
  if (isMedia) return DoubleTapAction.react;
  if (isText && isDecrypted && !isEnvelope) return DoubleTapAction.copyMode;
  return DoubleTapAction.none;
}

/// Whether a tap on the reaction pill joins in (sets the same reaction or
/// takes one's own back) instead of opening the list of who reacted: only in a
/// group, and only when there is one kind of reaction to join.
bool pillTapJoins({
  required bool isGroup,
  required int reactionKinds,
  required bool canInteract,
}) =>
    isGroup && canInteract && reactionKinds == 1;
