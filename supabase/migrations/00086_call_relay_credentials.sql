-- SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
-- SPDX-License-Identifier: AGPL-3.0-or-later
-- ============================================================================
-- 00086: Call relay credentials — our own STUN/TURN (calls, stage 2)
-- ----------------------------------------------------------------------------
-- Stage 1 connected calls on the same network only: no third-party STUN
-- server, on purpose (it would see the IP of everyone who calls, and when).
-- Stage 2 runs our own coturn, and this function hands out the short-lived
-- credentials it accepts.
--
-- The scheme is coturn's "TURN REST API" (use-auth-secret): username =
-- "<expiry-unix>:<random>", credential = base64(HMAC-SHA1(secret, username)).
-- coturn recomputes the HMAC with the same secret and checks the expiry —
-- no user table on the relay, nothing to sync.
--
-- The random half is deliberate. coturn logs the username of every
-- allocation; with a user id in it, the relay would keep a list of who
-- called when. A random tag ties nothing to an account.
--
-- Who gets credentials: the same pair that may ring each other in
-- send_call_signal (00085) — a 1:1 chat both are in, with an accepted chat
-- request. Without that gate any fresh anonymous account would get a free
-- relay. A BLOCK is not checked here on purpose: refusing credentials would
-- tell a blocked caller what the silent signal (00085) hides.
--
-- What the relay sees: two IP addresses, a time, and encrypted bytes. The
-- audio is DTLS-SRTP end to end; the relay forwards it without the keys.
--
-- Configuration lives in Vault, not here (scripts/netcup/turn/):
--   turn_secret  the shared secret, also in coturn's static-auth-secret
--   turn_uris    comma-separated, e.g.
--                stun:turn.chattr.at:3478,turn:turn.chattr.at:3478?transport=udp
-- Not configured → an empty list, which is exactly stage 1.
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

CREATE OR REPLACE FUNCTION public.get_call_ice_servers(
  p_chat_id UUID,
  p_peer UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  v_me UUID := auth.uid();
  v_secret TEXT;
  v_uris TEXT;
  v_stun TEXT[];
  v_turn TEXT[];
  v_user TEXT;
  -- A day: an allocation is refreshed with the same credentials for as long
  -- as the call runs, and an expired one drops the call mid-sentence.
  v_ttl CONSTANT INTEGER := 86400;
  v_out JSONB := '[]'::JSONB;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501';
  END IF;
  IF p_peer IS NULL OR p_peer = v_me THEN
    RAISE EXCEPTION 'invalid peer' USING ERRCODE = '22023';
  END IF;

  -- Same gate as send_call_signal (00085), minus the block (see above).
  IF NOT EXISTS (
    SELECT 1 FROM public.chats c
     WHERE c.id = p_chat_id
       AND c.is_group = FALSE
       AND c.banned_at IS NULL
       AND EXISTS (SELECT 1 FROM public.chat_members m
                    WHERE m.chat_id = c.id AND m.user_id = v_me)
       AND EXISTS (SELECT 1 FROM public.chat_members m
                    WHERE m.chat_id = c.id AND m.user_id = p_peer)
  ) OR NOT EXISTS (
    SELECT 1 FROM public.chat_requests r
     WHERE r.accepted
       AND ((r.requester_id = v_me AND r.target_id = p_peer)
         OR (r.requester_id = p_peer AND r.target_id = v_me))
  ) THEN
    RAISE EXCEPTION 'not a callable pair' USING ERRCODE = '42501';
  END IF;

  v_uris := private.get_secret('turn_uris');
  IF v_uris IS NULL OR btrim(v_uris) = '' THEN
    RETURN v_out;
  END IF;

  SELECT array_agg(u) FILTER (WHERE u LIKE 'stun:%' OR u LIKE 'stuns:%'),
         array_agg(u) FILTER (WHERE u LIKE 'turn:%' OR u LIKE 'turns:%')
    INTO v_stun, v_turn
    FROM (SELECT btrim(x) AS u
            FROM unnest(string_to_array(v_uris, ',')) AS x) s
   WHERE u <> '';

  IF v_stun IS NOT NULL THEN
    v_out := v_out || jsonb_build_array(jsonb_build_object('urls', v_stun));
  END IF;

  v_secret := private.get_secret('turn_secret');
  -- TURN without its secret would only hand out credentials coturn rejects;
  -- STUN alone still lets calls cross most home routers.
  IF v_turn IS NOT NULL AND v_secret IS NOT NULL AND v_secret <> '' THEN
    v_user := (extract(epoch FROM now())::BIGINT + v_ttl)::TEXT || ':'
              || encode(extensions.gen_random_bytes(8), 'hex');
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'urls', v_turn,
      'username', v_user,
      'credential', encode(extensions.hmac(v_user, v_secret, 'sha1'), 'base64')
    ));
  END IF;

  RETURN v_out;
END;
$$;

REVOKE ALL ON FUNCTION public.get_call_ice_servers(UUID, UUID)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_call_ice_servers(UUID, UUID)
  TO authenticated;

COMMENT ON FUNCTION public.get_call_ice_servers IS
  'Liefert die STUN/TURN-Server für einen Anruf samt kurzlebigem TURN-Zugang '
  '(coturn REST-API, HMAC). Nur für ein anrufbares 1:1-Paar. Leer, solange '
  'turn_uris im Vault fehlt.';
