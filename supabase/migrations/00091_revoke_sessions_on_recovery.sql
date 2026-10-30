-- SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
-- SPDX-License-Identifier: AGPL-3.0-or-later
--
-- A recovery must leave the account on exactly ONE installation.
--
-- Found 2026-10-11: after a recovery on a new device the old installation kept
-- its session. On every start it republished its identity key and its per-chat
-- keys over the new device's ("… hat neue Schlüssel erzeugt" in every chat),
-- and the new device wrote back the next time it opened. recover-identity now
-- ends every existing session of the account BEFORE it issues the new one, so
-- the old installation lands on the login screen at its next token refresh.
-- Its data stays on the device (AppInit only wipes on user_not_found).
--
-- An access token that was already issued stays valid until it expires (about
-- an hour); PostgREST checks the signature, not the session. For that window
-- the client-side guard (installation_status.dart) keeps an updated old
-- installation from writing keys.

CREATE OR REPLACE FUNCTION public.revoke_all_sessions(p_user_id UUID)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = auth, pg_temp
AS $$
DECLARE
  removed INTEGER;
BEGIN
  -- refresh_tokens hang off sessions with ON DELETE CASCADE.
  DELETE FROM auth.sessions WHERE user_id = p_user_id;
  GET DIAGNOSTICS removed = ROW_COUNT;
  RETURN removed;
END;
$$;

-- Only the edge function (service role) may call this. Anyone else could log
-- an arbitrary account out of every device.
REVOKE ALL ON FUNCTION public.revoke_all_sessions(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.revoke_all_sessions(UUID) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.revoke_all_sessions(UUID) TO service_role;

COMMENT ON FUNCTION public.revoke_all_sessions(UUID) IS
  'Ends every session of p_user_id (recover-identity, before the new session '
  'is issued). service_role only.';
