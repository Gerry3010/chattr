-- SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
-- SPDX-License-Identifier: AGPL-3.0-or-later

-- ============================================================================
-- Security audit 2026-07-16 — P1 fix (findings H4, M11, L7, L8).
--
-- Root cause: PostgreSQL grants EXECUTE on every new function to PUBLIC by
-- default. Several SECURITY DEFINER functions never had that grant revoked, so
-- `anon` and `authenticated` could call them directly via PostgREST
-- (`POST /rest/v1/rpc/<fn>`) — bypassing the authorization the function itself
-- never performs. The properly-secured RPCs (mark_message_read, edit_message,
-- toggle_message_reaction, …) all check auth.uid() internally, so their
-- exposure is fine; the functions below do NOT and must not be publicly callable.
--
-- Verified against live prod + staging that no legitimate caller relies on the
-- public grant:
--   • insert_system_message   — invoked only by SECURITY DEFINER triggers
--                               (notify_admin_promotion / notify_key_rotation /
--                               notify_membership_change), all owned by postgres
--                               → they execute as owner and keep access.
--   • cleanup_old_messages     — pg_cron (runs as postgres).
--   • delete_expired_messages  — pg_cron (runs as postgres).
--   • register_version         — no caller; sync-backend-version.sh writes
--                               app_versions directly via psql as postgres.
--   • get_reaction_users       — USED by the app (authenticated), so it is NOT
--                               revoked; instead it gains an internal membership
--                               check and stays callable by authenticated only.
-- ============================================================================

-- --- H4: system-message forgery (confused deputy via service_role) -----------
-- Trigger-only. Nobody external should reach it.
REVOKE EXECUTE ON FUNCTION public.insert_system_message(uuid, text, uuid, text)
  FROM PUBLIC, anon, authenticated, service_role;

-- --- L8: anon-triggerable global retention deletes ---------------------------
-- Maintenance functions; pg_cron runs them as postgres.
REVOKE EXECUTE ON FUNCTION public.cleanup_old_messages()
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.delete_expired_messages()
  FROM PUBLIC, anon, authenticated, service_role;

-- --- L7: anon-writable version / update channel ------------------------------
-- Deploy-time only; the deploy script writes app_versions directly as postgres.
REVOKE EXECUTE ON FUNCTION public.register_version(text, text, text, jsonb)
  FROM PUBLIC, anon, authenticated, service_role;

-- --- M11: get_reaction_users cross-chat IDOR ---------------------------------
-- The app calls this to show WHO reacted with a given emoji, so it must stay
-- callable by authenticated users — but SECURITY DEFINER made it bypass RLS and
-- leak usernames + reactions across chat boundaries for any known message_id.
-- Add an explicit membership check (the caller must belong to the chat the
-- message is in) and drop anon/PUBLIC access.
CREATE OR REPLACE FUNCTION public.get_reaction_users(p_message_id uuid, p_reaction text)
  RETURNS TABLE(user_id uuid, username text, created_at timestamp with time zone)
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = public, pg_temp
AS $function$
BEGIN
  -- Authorize: the caller must be a member of the chat this message belongs to.
  -- Without this, a definer bypass let anyone with a message_id enumerate the
  -- reactors + their usernames across chats they are not in.
  IF NOT EXISTS (
    SELECT 1
    FROM messages m
    JOIN chat_members cm ON cm.chat_id = m.chat_id
    WHERE m.id = p_message_id
      AND cm.user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'not authorized to read reactions for this message'
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT mr.user_id, p.username, mr.created_at
  FROM message_reactions mr
  JOIN profiles p ON p.id = mr.user_id
  WHERE mr.message_id = p_message_id
    AND mr.reaction = p_reaction
  ORDER BY mr.created_at ASC;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.get_reaction_users(uuid, text)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_reaction_users(uuid, text)
  TO authenticated;

COMMENT ON FUNCTION public.get_reaction_users(uuid, text) IS
  'Returns users who reacted with a specific emoji. SECURITY DEFINER but gated: '
  'caller must be a member of the message''s chat (audit 2026-07-16, M11).';
