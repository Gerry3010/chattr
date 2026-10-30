-- SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
-- SPDX-License-Identifier: AGPL-3.0-or-later

-- ============================================================================
-- 00070: Make edited messages deletable again
-- ----------------------------------------------------------------------------
-- Found on 2026-08-06 on prod: 17 messages lay on the server WITH content
-- although long since delivered. All 17 had `edited_at` set — 100 %
-- correlation, no exception.
--
-- **The mechanics.** `mark_message_received()` cleared the content only under
-- `received_at IS NULL`. When editing, the sender writes new ciphertext into
-- the row (policy "Senders can update their messages"); if it has already been
-- delivered by then, `received_at` is already set, and the clearing **never
-- applies again**. The new text stays there permanently.
--
-- **The client already does everything right.** `global_message_handler`
-- fetches the edited row, decrypts, stores locally and then explicitly calls
-- `markAsReceived` to clear the server again ("Re-clear the server ciphertext
-- now that we've consumed the new content", since 2026-06-21). Exactly that
-- second call ran into the `IF NOT FOUND` and threw "Message not found or
-- already received". The fault sits here alone.
--
-- That contradicts the public promise "delivered = deleted" (blog post "The
-- server forgets"), which is why the existing stock is cleaned up as well — see
-- the reasoning below.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.mark_message_received(
  p_message_id UUID,
  p_chat_id    UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
-- New: a pinned search_path. The function had none until now — with a SECURITY
-- DEFINER function that is the standard hardening (as in 00069).
SET search_path = 'public', 'pg_temp'
AS $function$
BEGIN
  UPDATE messages
  SET
    -- The delivery time stays the FIRST one. An edit is not a new delivery —
    -- were the time to move forward, the delivery tick would jump to a later
    -- moment at the sender, although the message had long since arrived.
    received_at = COALESCE(received_at, NOW()),
    encrypted_content = '',
    -- Delivered: the recipient has the decrypted quote locally, nobody needs it
    -- server-side any more.
    reply_to_preview = NULL,
    reply_to_sender_name = NULL
  WHERE id = p_message_id
    AND chat_id = p_chat_id
    AND recipient_id = auth.uid()
    -- Until now only `received_at IS NULL`. The second case is the edit:
    -- already delivered, but there is content lying there again that the client
    -- has just consumed. A double call on an already cleared row still hits
    -- nothing and throws as before.
    AND (received_at IS NULL OR encrypted_content <> '');

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Message not found or already received';
  END IF;
END;
$function$;

COMMENT ON FUNCTION public.mark_message_received(UUID, UUID) IS
  'Zustellung quittieren und den Chiffretext serverseitig löschen. Greift auch '
  'ein ZWEITES Mal, wenn eine bereits zugestellte Nachricht bearbeitet wurde '
  'und dadurch wieder Inhalt trägt (00070) — sonst bliebe der neue Text für '
  'immer liegen. Der Zustellzeitpunkt bleibt dabei der erste.';

-- ----------------------------------------------------------------------------
-- Clean up the existing stock.
--
-- Safe because the client demonstrably already has the content: the re-clear
-- path in the client has existed since 2026-06-21, the oldest affected row is
-- from 2026-07-14. Every one of these rows has therefore gone the way "fetch →
-- decrypt → STORE LOCALLY → markAsReceived"; the client aborts before the
-- markAsReceived if the local store fails. Only the last step failed, and it
-- failed on the condition this migration corrects.
--
-- Deliberately NOT solved via `mark_message_received` (that needs the
-- respective recipient's `auth.uid()`) but directly — it is a one-off cleanup
-- of what should have been deleted anyway.
-- ----------------------------------------------------------------------------
DO $$
DECLARE
  geraeumt INTEGER;
BEGIN
  UPDATE public.messages
  SET encrypted_content = '',
      reply_to_preview = NULL,
      reply_to_sender_name = NULL
  WHERE received_at IS NOT NULL
    AND encrypted_content <> '';
  GET DIAGNOSTICS geraeumt = ROW_COUNT;
  RAISE NOTICE '00070: % zugestellte Zeilen nachtraeglich geleert', geraeumt;
END $$;
