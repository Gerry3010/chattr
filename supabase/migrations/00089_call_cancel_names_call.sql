-- SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
-- SPDX-License-Identifier: AGPL-3.0-or-later
-- ============================================================================
-- 00089: A call cancel names the call it cancels
-- ----------------------------------------------------------------------------
-- 00088 sent `call_cancel` with the chat id only. On iOS that is a problem:
-- every VoIP push MUST report a CallKit call (PushKit allows nothing else),
-- so a cancel had to report a NEW call and end it at once — a second call
-- flashing up over the one that rang (found by mac-claude while wiring
-- PushKit, 2026-10-05). Now the cancel carries the signal id of the invite
-- it takes back; iOS reports the call that is already ringing and ends it.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.send_call_signal(
  p_chat_id UUID,
  p_to UUID,
  p_signal_id UUID,
  p_envelope TEXT,
  p_kind TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  v_me UUID := auth.uid();
  v_cancelled UUID;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501';
  END IF;
  IF p_to IS NULL OR p_to = v_me THEN
    RAISE EXCEPTION 'invalid recipient' USING ERRCODE = '22023';
  END IF;
  IF p_envelope IS NULL OR octet_length(p_envelope) > 32768 THEN
    RAISE EXCEPTION 'invalid envelope' USING ERRCODE = '22023';
  END IF;
  IF p_kind IS NOT NULL AND p_kind NOT IN ('invite', 'cancel') THEN
    RAISE EXCEPTION 'invalid kind' USING ERRCODE = '22023';
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

  -- Blocked: silence, indistinguishable from an offline peer — and above all
  -- no push. On iOS a VoIP push MUST ring; the gate has to sit here.
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

  IF p_kind = 'invite' THEN
    -- Whatever is older than the acceptance window is dead anyway.
    DELETE FROM public.call_invites
     WHERE created_at < now() - interval '2 minutes';
    INSERT INTO public.call_invites
      (signal_id, chat_id, sender_id, recipient_id, envelope)
    VALUES (p_signal_id, p_chat_id, v_me, p_to, p_envelope)
    ON CONFLICT (signal_id) DO NOTHING;
    PERFORM private.push_call(p_to, 'call_invite', p_chat_id, p_signal_id);
  ELSIF p_kind = 'cancel' THEN
    -- The id of the invite being taken back travels with the cancel: iOS
    -- must report a CallKit call for EVERY VoIP push, and reporting the SAME
    -- call (same UUID) and ending it at once dismisses what rings — a fresh
    -- id would flash a second call first.
    WITH gone AS (
      DELETE FROM public.call_invites
       WHERE sender_id = v_me AND recipient_id = p_to
      RETURNING signal_id, created_at
    )
    SELECT signal_id INTO v_cancelled FROM gone
     ORDER BY created_at DESC LIMIT 1;
    PERFORM private.push_call(p_to, 'call_cancel', p_chat_id, v_cancelled);
  END IF;
END;
$$;


REVOKE ALL ON FUNCTION public.send_call_signal(UUID, UUID, UUID, TEXT, TEXT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.send_call_signal(UUID, UUID, UUID, TEXT, TEXT)
  TO authenticated;
