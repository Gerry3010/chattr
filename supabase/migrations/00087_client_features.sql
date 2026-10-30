-- SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
-- SPDX-License-Identifier: AGPL-3.0-or-later
-- ============================================================================
-- 00087: What the other side's app can do — starting with calls
-- ----------------------------------------------------------------------------
-- Calls (00085) arrived with 1.31. A peer on an older app has no call screen:
-- an invite reaches nobody, and the caller watches it ring into the void
-- until "no answer" (Gerry, 2026-10-04: "so könnte ich Sebi anrufen").
--
-- device_tokens.app_version (00076) cannot answer "can they take a call?":
-- it exists only for devices with push, and the web client has none. So each
-- app now SAYS what it supports, once per start (`announce_features`), and a
-- caller asks before ringing (`peer_can_take_calls`).
--
-- A per-account list, not per device: if any of a person's devices can ring,
-- calling them makes sense. Clients before 1.32 never announce, so they read
-- as "cannot" — which for 1.31 (calls, but no announcement) is one day of
-- false negatives, and the safe direction.
--
-- What it reveals: a short list of capability words, readable only by
-- someone who may call the account anyway (same pair gate as 00085/00086).
-- ============================================================================

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS features TEXT[] NOT NULL DEFAULT '{}';

COMMENT ON COLUMN public.profiles.features IS
  'Fähigkeiten der App dieses Kontos ("calls"), von der App selbst bei jedem '
  'Start gemeldet (announce_features). Leer = App vor 1.32.';

CREATE OR REPLACE FUNCTION public.announce_features(p_features TEXT[])
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
  -- A capability list, not a free-text field: short words, few of them.
  IF p_features IS NULL
     OR cardinality(p_features) > 16
     OR EXISTS (SELECT 1 FROM unnest(p_features) f
                 WHERE f !~ '^[a-z0-9_.]{1,32}$') THEN
    RAISE EXCEPTION 'invalid features' USING ERRCODE = '22023';
  END IF;
  UPDATE public.profiles
     SET features = (SELECT coalesce(array_agg(DISTINCT f ORDER BY f), '{}')
                       FROM unnest(p_features) f)
   WHERE id = v_me;
END;
$$;

CREATE OR REPLACE FUNCTION public.peer_can_take_calls(p_chat_id UUID, p_peer UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  v_me UUID := auth.uid();
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501';
  END IF;
  -- Same pair gate as send_call_signal / get_call_ice_servers: only someone
  -- who may ring this account learns what its app can do.
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
  RETURN EXISTS (SELECT 1 FROM public.profiles p
                  WHERE p.id = p_peer AND 'calls' = ANY (p.features));
END;
$$;

REVOKE ALL ON FUNCTION public.announce_features(TEXT[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.announce_features(TEXT[]) TO authenticated;
REVOKE ALL ON FUNCTION public.peer_can_take_calls(UUID, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.peer_can_take_calls(UUID, UUID) TO authenticated;
