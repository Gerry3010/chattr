-- SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
-- SPDX-License-Identifier: AGPL-3.0-or-later

-- ============================================================================
-- 00073: the reaction emoji in the push is now ON by default
-- ----------------------------------------------------------------------------
-- 00072 introduced the column with `DEFAULT FALSE` — my recommendation, because
-- the emoji is message content and has to pass through Google or Apple to
-- appear in the notification. Gerry's decision, knowing that trade-off: on by
-- default. The trade-off itself does not change, only who makes it for
-- themselves by default — it remains switchable as before (settings → privacy).
--
-- That puts it on the same line as `push_media_kind` (00067, also DEFAULT
-- TRUE): an ingredient of the notification on one's own device that the
-- recipient can turn off at any time.
--
-- **Why the existing stock is brought along.** A pure DEFAULT change applies
-- only to NEW rows; all existing profiles would keep FALSE, and "on by default"
-- would be true for practically nobody. Checked before writing: all 92 profiles
-- stand at FALSE, so nobody has ever set the switch deliberately (the column is
-- half a day old and was FALSE-by-default the whole time). The UPDATE therefore
-- overwrites no decision; it establishes the state 00072 would have had, had it
-- shipped with TRUE straight away.
--
-- Were this needed again later, that would NO LONGER hold: once somebody has
-- flipped the switch deliberately, a default change must not touch the existing
-- stock any more.
-- ============================================================================

ALTER TABLE public.profiles
  ALTER COLUMN push_reaction_emoji SET DEFAULT TRUE;

COMMENT ON COLUMN public.profiles.push_reaction_emoji IS
  'Darf das Reaktions-Emoji im Push an den Push-Dienst (FCM/APNs) mitgehen, '
  'damit die Benachrichtigung „X hat mit 👍 reagiert" lauten kann? Entscheidung '
  'des Empfängers, Voreinstellung TRUE (00073; 00072 startete mit FALSE). '
  'FALSE = der Push bleibt bei „X hat auf deine Nachricht reagiert".';

UPDATE public.profiles SET push_reaction_emoji = TRUE
WHERE push_reaction_emoji = FALSE;
