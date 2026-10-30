-- SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
-- SPDX-License-Identifier: AGPL-3.0-or-later
-- ============================================================================
-- 00088: Calls ring a closed app (stage 3)
-- ----------------------------------------------------------------------------
-- Until now an invite reached only a device whose app was open: it travels
-- over the realtime bus, and a closed app is not listening. Stage 3 wakes the
-- device with a push — FCM high priority on Android, a VoIP push via APNs on
-- iOS (which must show CallKit at once; PushKit allows nothing else).
--
-- What the push carries (Gerry, 2026-10-04): {type, chat_id, signal_id} —
-- no caller id, no name. Apple and Google learn that this device gets a call
-- from Chattr and when; not from whom. The device puts the name in itself,
-- from the table it already keeps for message pushes.
--
-- The sealed invite does NOT fit into the push: hybrid KEM + signature + SDP
-- come to roughly 4-6 KB, FCM allows 4 KB, APNs-VoIP 5 KB. So the server
-- keeps it — sealed, unreadable to it — in `call_invites` until the woken
-- device fetches it, and at most two minutes (the same window in which the
-- client accepts it at all, call_signal.dart). Fetching deletes it. This is
-- a departure from "nothing is stored" (00085), and it is said so in the
-- changelog and the blog rather than hidden.
--
-- The server must know WHICH signal is an invite to push for it, so the
-- caller now says so in plain (`p_kind`). It already saw who calls whom and
-- when; "this one rings" adds nothing beyond that.
-- ============================================================================

-- VoIP tokens are a different kind of token: issued by PushKit, accepted only
-- by APNs (never FCM), and they must never receive an ordinary push — iOS
-- would demand a CallKit call for it and punish the app when none comes.
ALTER TABLE public.device_tokens
  DROP CONSTRAINT IF EXISTS device_tokens_platform_check;
ALTER TABLE public.device_tokens
  ADD CONSTRAINT device_tokens_platform_check
  CHECK (platform = ANY (ARRAY['android', 'ios', 'web', 'ios_voip']));

CREATE TABLE IF NOT EXISTS public.call_invites (
  signal_id    UUID PRIMARY KEY,
  chat_id      UUID NOT NULL REFERENCES public.chats(id) ON DELETE CASCADE,
  sender_id    UUID NOT NULL,
  recipient_id UUID NOT NULL,
  envelope     TEXT NOT NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS call_invites_recipient_idx
  ON public.call_invites (recipient_id);

-- No policies: only the functions below touch it.
ALTER TABLE public.call_invites ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.call_invites FROM PUBLIC, anon, authenticated;

COMMENT ON TABLE public.call_invites IS
  'Versiegelte Anruf-Einladungen für ein Gerät, das per Push geweckt wird. '
  'Unlesbar für den Server, höchstens 2 Minuten, beim Abholen gelöscht.';

-- Asks the push function to wake [p_to]'s devices. Best-effort: a push that
-- cannot be sent must not fail the signal, which still travels the bus.
CREATE OR REPLACE FUNCTION private.push_call(
  p_to UUID, p_type TEXT, p_chat_id UUID, p_signal_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
BEGIN
  PERFORM net.http_post(
    url := COALESCE(
      current_setting('app.settings.edge_function_url', true),
      'http://kong:8000/functions/v1/send-push-notification'
    ),
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || private.get_secret('service_role_key')
    ),
    body := jsonb_build_object(
      'type', p_type,
      'user_ids', ARRAY[p_to],
      'title', '',
      'body', '',
      'data', jsonb_strip_nulls(jsonb_build_object(
        'type', p_type,
        'chat_id', p_chat_id::text,
        'signal_id', p_signal_id::text
      ))
    )
  );
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'push_call failed: %', SQLERRM;
END;
$$;
REVOKE ALL ON FUNCTION private.push_call(UUID, TEXT, UUID, UUID)
  FROM PUBLIC, anon, authenticated;

-- send_call_signal gains `p_kind`. Dropped and recreated rather than
-- overloaded: with a default, the 1.31 client's four named arguments still
-- resolve to this one function, and there is no second one to forget.
DROP FUNCTION IF EXISTS public.send_call_signal(UUID, UUID, UUID, TEXT);

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
    DELETE FROM public.call_invites
     WHERE sender_id = v_me AND recipient_id = p_to;
    PERFORM private.push_call(p_to, 'call_cancel', p_chat_id, NULL);
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.send_call_signal(UUID, UUID, UUID, TEXT, TEXT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.send_call_signal(UUID, UUID, UUID, TEXT, TEXT)
  TO authenticated;

-- The woken device fetches its invite: once, only its own, only while fresh.
CREATE OR REPLACE FUNCTION public.fetch_call_invite(p_signal_id UUID)
RETURNS TABLE (chat_id UUID, sender_id UUID, envelope TEXT)
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
  RETURN QUERY
    DELETE FROM public.call_invites i
     WHERE i.signal_id = p_signal_id
       AND i.recipient_id = v_me
       AND i.created_at >= now() - interval '2 minutes'
    RETURNING i.chat_id, i.sender_id, i.envelope;
END;
$$;

REVOKE ALL ON FUNCTION public.fetch_call_invite(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fetch_call_invite(UUID) TO authenticated;
