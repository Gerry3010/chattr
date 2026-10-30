-- SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
-- SPDX-License-Identifier: AGPL-3.0-or-later
-- ============================================================================
-- 00085: Call signaling — one narrow door into the peer's event bus
-- ----------------------------------------------------------------------------
-- A 1:1 audio call needs its two devices to swap an offer, an answer and a
-- handful of ICE candidates within seconds. The user's private bus (00063,
-- `p:user:<id>`) already reaches every device that is online; what is missing
-- is a way for ONE CLIENT to put something on ANOTHER user's bus. 00084 just
-- closed the door that did that for anything; this opens a narrow one for
-- exactly this.
--
-- What the server does NOT see: the signal itself. The client seals it like a
-- message — hybrid KEM to the peer's chat key, Ed25519 identity signature,
-- AAD bound to chat‖sender‖signal-id — and this function forwards an opaque
-- envelope. That matters more than usual: the SDP carries the DTLS
-- fingerprints that key the audio, and a server able to swap them could sit
-- in the middle of every call. Sealed and signed, it cannot.
--
-- Nothing is stored. No messages row, no table — a signal nobody is online to
-- receive is simply lost, which for a ringing phone is the right answer.
--
-- Who may ring whom:
--   * only in a 1:1 chat (no group calls in stage 1), both still members;
--   * only with an ACCEPTED chat request between the two (00082). The
--     membership gate from 00082 is not armed yet, so membership alone would
--     let a stranger who adds you to a 1:1 also ring your phone. Existing
--     1:1 chats are covered by the backfill in 00082;
--   * not across a block, in either direction (00031). A blocked caller gets
--     the same silence as an offline peer — a refusal would tell them they
--     are blocked;
--   * not from or into a banned chat (00060).
-- The sender id is taken from auth.uid(), never from the payload, so the
-- recipient learns WHO rang from the server and verifies it against the
-- signature.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.send_call_signal(
  p_chat_id UUID,
  p_to UUID,
  p_signal_id UUID,
  p_envelope TEXT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  v_me UUID := auth.uid();
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501';
  END IF;
  IF p_to IS NULL OR p_to = v_me THEN
    RAISE EXCEPTION 'invalid recipient' USING ERRCODE = '22023';
  END IF;
  -- A sealed SDP offer is a few KB. The cap keeps the bus from becoming a
  -- bulk channel; realtime itself would refuse far larger payloads anyway.
  IF p_envelope IS NULL OR octet_length(p_envelope) > 32768 THEN
    RAISE EXCEPTION 'invalid envelope' USING ERRCODE = '22023';
  END IF;

  -- 1:1, not banned, both members.
  IF NOT EXISTS (
    SELECT 1 FROM public.chats c
     WHERE c.id = p_chat_id
       AND c.is_group = FALSE
       AND c.banned_at IS NULL
       AND EXISTS (SELECT 1 FROM public.chat_members m
                    WHERE m.chat_id = c.id AND m.user_id = v_me)
       AND EXISTS (SELECT 1 FROM public.chat_members m
                    WHERE m.chat_id = c.id AND m.user_id = p_to)
  ) THEN
    RAISE EXCEPTION 'not a direct chat of both' USING ERRCODE = '42501';
  END IF;

  -- Consent.
  IF NOT EXISTS (
    SELECT 1 FROM public.chat_requests r
     WHERE r.accepted
       AND ((r.requester_id = v_me AND r.target_id = p_to)
         OR (r.requester_id = p_to AND r.target_id = v_me))
  ) THEN
    RAISE EXCEPTION 'no accepted chat request' USING ERRCODE = '42501';
  END IF;

  -- Blocked: silence, indistinguishable from an offline peer.
  IF public.is_blocked_pair(v_me, p_to) THEN
    RETURN;
  END IF;

  PERFORM public.chattr_send(
    jsonb_build_object(
      'type', 'callSignal',
      'chat_id', p_chat_id,
      'sender_id', v_me,
      'signal_id', p_signal_id,
      'envelope', p_envelope
    ),
    'event',
    'user:' || p_to::text,
    TRUE
  );
END;
$$;

REVOKE ALL ON FUNCTION public.send_call_signal(UUID, UUID, UUID, TEXT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.send_call_signal(UUID, UUID, UUID, TEXT)
  TO authenticated;

COMMENT ON FUNCTION public.send_call_signal IS
  'Leitet ein versiegeltes Anruf-Signal (Angebot/Antwort/ICE/Ende) an den '
  'Event-Kanal des Gegenübers weiter. Nur 1:1, nur mit angenommener Anfrage, '
  'nicht über eine Sperre hinweg. Speichert nichts.';
