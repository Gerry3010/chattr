-- SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
-- SPDX-License-Identifier: AGPL-3.0-or-later

-- ============================================================================
-- Security audit 2026-07-16 — M1 fix: close the profiles enumeration hole.
--
-- Root cause: the profiles SELECT policy was
--     USING (auth.uid() IS NOT NULL)
-- i.e. ANY authenticated user could read EVERY profile row. The app itself
-- only ever queries profiles by exact id (`.eq('id', …)` / `.inFilter('id', …)`),
-- so this over-broad grant was never needed by a legitimate client — but a
-- direct PostgREST call (`GET /rest/v1/profiles?select=*`) let any account dump
-- the full user directory (all usernames + avatar paths + ids).
--
-- Fix: scope SELECT to the profiles the caller has a legitimate relationship
-- with. A code audit (see task #111) confirmed every in-app profile read is one
-- of these four cases — there is NO pre-membership read and NO username search
-- to break:
--   1. self
--   2. a co-member (we are both members of the same chat)
--   3. a pending join-requester in a chat the caller administers
--      (admin approval screen / MCP listPending)
--   4. a user on the caller's own block list (blocked-users screen)
--
-- Deliberately NOT added: a get_profile_by_id() SECURITY DEFINER lookup RPC.
-- No caller needs it, and a "return any profile by id" primitive would just
-- reopen a (weaker, id-guessing) enumeration path.
--
-- Recursion note: the SELECT policy must read chat_members / pending_chat_members
-- / chats / blocked_users, which carry their own RLS. To avoid "infinite
-- recursion detected in policy", the membership test runs inside a SECURITY
-- DEFINER helper that bypasses RLS — the same pattern the schema already uses
-- for chat_members via is_chat_member() (00002_functions.sql).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.can_view_profile(p_profile_id uuid)
  RETURNS boolean
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path = public, pg_temp
AS $function$
  SELECT
    -- (1) self
    p_profile_id = auth.uid()
    -- (2) co-member: caller and target share at least one chat
    OR EXISTS (
      SELECT 1
      FROM chat_members me
      JOIN chat_members them ON them.chat_id = me.chat_id
      WHERE me.user_id = auth.uid()
        AND them.user_id = p_profile_id
    )
    -- (3) target is a pending join-requester in a chat the caller administers
    OR EXISTS (
      SELECT 1
      FROM pending_chat_members pcm
      JOIN chats c ON c.id = pcm.chat_id
      WHERE pcm.user_id = p_profile_id
        AND auth.uid() = ANY(c.admins)
    )
    -- (4) target is on the caller's own block list
    OR EXISTS (
      SELECT 1
      FROM blocked_users b
      WHERE b.blocker_id = auth.uid()
        AND b.blocked_id = p_profile_id
    );
$function$;

COMMENT ON FUNCTION public.can_view_profile(uuid) IS
  'Authorization predicate for the profiles SELECT policy: caller may read the '
  'target profile iff it is self, a co-member, a pending requester in a chat the '
  'caller admins, or on the caller''s block list (audit 2026-07-16, M1).';

-- Only authenticated users evaluate the predicate; anon has no business reading
-- profiles at all (anonymous Supabase auth still yields an authenticated JWT).
REVOKE EXECUTE ON FUNCTION public.can_view_profile(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.can_view_profile(uuid) TO authenticated;

-- Swap the over-broad policy for the scoped one.
DROP POLICY IF EXISTS "Authenticated users can view profiles" ON profiles;

CREATE POLICY "Users can view profiles in their context"
ON profiles FOR SELECT
TO authenticated
USING (public.can_view_profile(id));

COMMENT ON POLICY "Users can view profiles in their context" ON profiles IS
  'Scoped profile visibility: self, co-members, pending requesters in chats the '
  'caller admins, and blocked users. Closes the full-directory enumeration hole '
  '(audit 2026-07-16, M1).';
