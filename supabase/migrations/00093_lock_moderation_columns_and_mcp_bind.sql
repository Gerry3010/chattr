-- 00093: close two privilege holes found in the 2026-10-25 security check, and
-- pin the search_path of the remaining SECURITY DEFINER functions.
--
-- 1. CHAT-17 — a banned user could unban themselves. The "Users can update
--    their own profile" policy (00005) checks only auth.uid() = id, and the
--    moderation columns from 00060 (banned_at, false_flags,
--    last_false_flag_at, flagging_revoked_at) live in that very row, so a
--    plain PATCH set banned_at back to NULL. Same shape on chats: a group
--    admin could lift chats.banned_at or set is_mcp / mcp_owner_id /
--    mcp_token_id directly. A guard trigger now refuses changes to those
--    columns from the API roles. The mod_* functions and bind_mcp_chat run
--    SECURITY DEFINER as their owner and are not affected; neither is
--    service_role (admin dashboard). A trigger rather than column grants on
--    purpose: a column added later stays writable for the client unless it
--    is listed here, instead of failing with "permission denied" the day
--    someone forgets a GRANT.
--
-- 2. CHAT-16 — any member could take over a group. bind_mcp_chat only
--    checked membership, so a member minted their own MCP token, bound an
--    existing group to themselves, filed a pending row, and
--    auto_approve_mcp_owner (00044) made them the SOLE admin. Binding now
--    requires the caller to be an admin and the only member, which is
--    exactly the state the MCP server is in right after creating a project
--    chat (mcp_server/src/chats.ts). The auto-approve trigger gets a second
--    lock: it only promotes while the agent is the only other member.
--
-- 3. CHAT-19 — 13 SECURITY DEFINER functions in public had no fixed
--    search_path, among them is_chat_member and is_chat_admin, which carry
--    most RLS policies. pg_temp would be searched first, so a session that
--    can create a temp table could shadow chat_members and pass any
--    membership check. Not reachable through PostgREST today (no DDL), but
--    one leaked direct connection away from a full RLS bypass.
--
-- 4. CHAT-19 — on prod, four functions were anon-callable that are not
--    locally: the default ACL grants EXECUTE to anon directly, so the
--    migrations' REVOKE ... FROM PUBLIC never removed it. They all check
--    auth.uid(), so nothing leaked, but it is the class of mistake that made
--    chattr_send callable by anyone (00084). Revoked here, and new functions
--    no longer default to anon.

-- ── 1. Moderation and binding columns are not client-writable ────────────

CREATE OR REPLACE FUNCTION public.guard_profile_moderation_columns()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  -- Only the API roles are fenced in. Inside a SECURITY DEFINER function
  -- current_user is that function's owner, so mod_ban_user & co. pass.
  IF current_user NOT IN ('authenticated', 'anon') THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'INSERT' THEN
    -- is_agent stays settable at signup: the MCP server declares its
    -- profile an agent when it creates it (mcp_server/src/supabase.ts).
    IF NEW.banned_at IS NOT NULL
       OR NEW.false_flags <> 0
       OR NEW.last_false_flag_at IS NOT NULL
       OR NEW.flagging_revoked_at IS NOT NULL THEN
      RAISE EXCEPTION 'moderation fields can only be set by moderation'
        USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.banned_at IS DISTINCT FROM OLD.banned_at
     OR NEW.false_flags IS DISTINCT FROM OLD.false_flags
     OR NEW.last_false_flag_at IS DISTINCT FROM OLD.last_false_flag_at
     OR NEW.flagging_revoked_at IS DISTINCT FROM OLD.flagging_revoked_at
     OR NEW.is_agent IS DISTINCT FROM OLD.is_agent THEN
    RAISE EXCEPTION 'moderation fields can only be changed by moderation'
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS guard_profile_moderation_columns_trigger ON public.profiles;
CREATE TRIGGER guard_profile_moderation_columns_trigger
  BEFORE INSERT OR UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.guard_profile_moderation_columns();

CREATE OR REPLACE FUNCTION public.guard_chat_privileged_columns()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  IF current_user NOT IN ('authenticated', 'anon') THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'INSERT' THEN
    -- A chat born with is_mcp + somebody's mcp_owner_id would be picked up
    -- by that person's app as their agent chat. Binding is bind_mcp_chat's
    -- job alone.
    IF NEW.banned_at IS NOT NULL
       OR NEW.is_mcp
       OR NEW.mcp_owner_id IS NOT NULL
       OR NEW.mcp_token_id IS NOT NULL THEN
      RAISE EXCEPTION 'moderation and agent binding fields are server-set'
        USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.banned_at IS DISTINCT FROM OLD.banned_at
     OR NEW.is_mcp IS DISTINCT FROM OLD.is_mcp
     OR NEW.mcp_owner_id IS DISTINCT FROM OLD.mcp_owner_id
     OR NEW.mcp_token_id IS DISTINCT FROM OLD.mcp_token_id THEN
    RAISE EXCEPTION 'moderation and agent binding fields are server-set'
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS guard_chat_privileged_columns_trigger ON public.chats;
CREATE TRIGGER guard_chat_privileged_columns_trigger
  BEFORE INSERT OR UPDATE ON public.chats
  FOR EACH ROW EXECUTE FUNCTION public.guard_chat_privileged_columns();

-- Trigger functions are not meant to be called as RPCs.
REVOKE ALL ON FUNCTION public.guard_profile_moderation_columns() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.guard_chat_privileged_columns() FROM PUBLIC, anon, authenticated;

-- ── 2. Binding an MCP chat needs a fresh chat the caller administers ────

CREATE OR REPLACE FUNCTION public.bind_mcp_chat(p_chat_id UUID, p_token TEXT)
RETURNS UUID
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
LANGUAGE plpgsql
AS $$
DECLARE
  v_owner_id UUID;
  v_token_id UUID;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  -- Caller (the agent) must already be a member of the chat it's binding.
  IF NOT EXISTS (
    SELECT 1 FROM chat_members
    WHERE chat_members.chat_id = p_chat_id
      AND chat_members.user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'Not a member of chat %', p_chat_id;
  END IF;

  -- ...and an admin of it, and its only member. That is the state right
  -- after the MCP server created the project chat. Before 00093 membership
  -- alone sufficed, and binding an existing group handed it to the caller
  -- through auto_approve_mcp_owner (CHAT-16).
  IF NOT EXISTS (
    SELECT 1 FROM chats
    WHERE id = p_chat_id AND auth.uid() = ANY(admins)
  ) THEN
    RAISE EXCEPTION 'Only an admin can bind chat %', p_chat_id
      USING ERRCODE = '42501';
  END IF;
  IF EXISTS (
    SELECT 1 FROM chat_members
    WHERE chat_id = p_chat_id AND user_id <> auth.uid()
  ) THEN
    RAISE EXCEPTION 'Chat % already has other members and cannot be bound', p_chat_id
      USING ERRCODE = '42501';
  END IF;

  SELECT id, owner_id INTO v_token_id, v_owner_id
  FROM mcp_tokens
  WHERE token_hash = encode(digest(p_token, 'sha256'), 'hex')
    AND revoked_at IS NULL;

  IF v_owner_id IS NULL THEN
    RAISE EXCEPTION 'Invalid or revoked MCP token';
  END IF;

  UPDATE chats
  SET is_mcp = true, mcp_owner_id = v_owner_id, mcp_token_id = v_token_id
  WHERE id = p_chat_id;

  RETURN v_owner_id;
END;
$$;

COMMENT ON FUNCTION public.bind_mcp_chat IS 'Binds a fresh chat (the caller is its admin and only member) to the human owner of the given MCP token — flags is_mcp, stamps mcp_owner_id + mcp_token_id so the owner''s app can auto-discover/join and so revoking the token can later remove the agent. Returns the owner id. Admin + sole-member check since 00093 (CHAT-16).';

CREATE OR REPLACE FUNCTION public.auto_approve_mcp_owner()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
LANGUAGE plpgsql
AS $$
BEGIN
  -- Only the bound owner of an MCP chat, and only for a live request (not a
  -- withdrawn/blocked one).
  IF NEW.blocked_at IS NULL AND EXISTS (
       SELECT 1 FROM chats
       WHERE id = NEW.chat_id
         AND is_mcp
         AND mcp_owner_id = NEW.user_id
     )
     -- Second lock (00093): only while the chat holds nobody but the agent
     -- that bound it. That is the state at the owner's first join; a chat
     -- with more people in it is a group, and handing a group to whoever
     -- bound it is exactly CHAT-16. Counted, not read from is_agent: agent
     -- profiles created before 00068 carry is_agent = false, and the MCP
     -- test suite creates its agents that way too.
     AND (
       SELECT count(*) FROM chat_members cm
       WHERE cm.chat_id = NEW.chat_id AND cm.user_id <> NEW.user_id
     ) <= 1 THEN
    -- Promote with the SAME public_key the owner submitted (E2E identity).
    INSERT INTO chat_members (chat_id, user_id, public_key)
      VALUES (NEW.chat_id, NEW.user_id, NEW.public_key)
      ON CONFLICT DO NOTHING;

    -- The human owner becomes the SOLE admin (demoting the agent). This is what
    -- lets the owner receive join-request broadcasts/pushes + approve them, and
    -- prevents a prompt-injected agent from managing the chat.
    UPDATE chats
      SET admins = ARRAY[NEW.user_id]
      WHERE id = NEW.chat_id
        AND admins IS DISTINCT FROM ARRAY[NEW.user_id];

    -- Clear the now-redundant pending row (idempotent with any app-side retry).
    DELETE FROM pending_chat_members
      WHERE chat_id = NEW.chat_id AND user_id = NEW.user_id;
  END IF;

  RETURN NULL; -- AFTER trigger; return value is ignored
END;
$$;

-- ── 3. Pin search_path on every SECURITY DEFINER function that lacks one ──
--
-- Listed by catalog rather than by hand, so a function the audit did not name
-- is covered too. `extensions` stays in the path because several bodies call
-- pgcrypto unqualified; pg_temp goes LAST, which is the whole point.
DO $$
DECLARE
  fn regprocedure;
BEGIN
  FOR fn IN
    SELECT p.oid::regprocedure
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.prosecdef
      AND NOT EXISTS (
        SELECT 1 FROM unnest(coalesce(p.proconfig, '{}')) c
        WHERE c LIKE 'search_path=%')
      AND NOT EXISTS (
        SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
  LOOP
    EXECUTE format('ALTER FUNCTION %s SET search_path = public, extensions, pg_temp', fn);
    RAISE NOTICE 'search_path pinned: %', fn;
  END LOOP;
END;
$$;

-- ── 4. anon loses EXECUTE it was never meant to have ─────────────────────

REVOKE EXECUTE ON FUNCTION public.claim_prekey(UUID, UUID) FROM anon;
REVOKE EXECUTE ON FUNCTION public.get_my_pending_requests() FROM anon;
REVOKE EXECUTE ON FUNCTION public.get_sent_message_status(timestamptz) FROM anon;
REVOKE EXECUTE ON FUNCTION public.mark_chat_read(uuid) FROM anon;

-- New functions created by the migration role no longer start out
-- anon-callable. authenticated keeps its default grant: dropping that would
-- turn every future RPC into a silent "permission denied" for the app.
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM anon;

NOTIFY pgrst, 'reload schema';
