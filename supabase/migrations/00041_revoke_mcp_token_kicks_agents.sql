-- ============================================================================
-- 00041: Revoking an MCP token also removes agent access to its bound chats
-- ----------------------------------------------------------------------------
-- Before this, revoke_mcp_token only stamped revoked_at (blocking FUTURE
-- bind_mcp_chat calls) — agents that had already joined chats via that token
-- kept their membership and could keep reading/sending. That's a security gap:
-- a compromised/retired token should cut the agents' existing access too.
--
-- To do that we need token→chat lineage, which bind_mcp_chat didn't record.
-- This migration:
--   (a) adds chats.mcp_token_id and has bind_mcp_chat stamp it,
--   (b) makes revoke_mcp_token, after marking the token revoked, remove every
--       NON-owner member (the agents) from chats bound by that token — the
--       human owner keeps their chat. The existing reassign_admin_on_leave
--       trigger then hands chat admin to the owner, and
--       notify_chat_deleted_on_member_removal tells each removed agent to drop
--       the chat locally.
--
-- Limitation: chats bound BEFORE this migration have mcp_token_id = NULL (the
-- old bind didn't record it), so revoking their token can't retroactively kick
-- those agents. Only binds from here on carry lineage.
-- ============================================================================

ALTER TABLE chats
  ADD COLUMN IF NOT EXISTS mcp_token_id UUID REFERENCES mcp_tokens(id) ON DELETE SET NULL;

COMMENT ON COLUMN chats.mcp_token_id IS 'The MCP token used to bind this chat (bind_mcp_chat). Revoking that token removes agent members (see revoke_mcp_token, migration 00041).';

-- bind_mcp_chat: additionally record which token bound the chat.
CREATE OR REPLACE FUNCTION bind_mcp_chat(p_chat_id UUID, p_token TEXT)
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

COMMENT ON FUNCTION bind_mcp_chat IS 'Binds a chat the caller (an agent) already belongs to, to the human owner of the given MCP token — flags is_mcp, stamps mcp_owner_id + mcp_token_id so the owner''s app can auto-discover/join and so revoking the token can later remove the agent. Returns the owner id.';

-- revoke_mcp_token: mark revoked AND remove agent members from bound chats.
CREATE OR REPLACE FUNCTION revoke_mcp_token(p_token_id UUID)
RETURNS VOID
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql
AS $$
DECLARE
  v_revoked BOOLEAN := false;
BEGIN
  UPDATE mcp_tokens
  SET revoked_at = NOW()
  WHERE id = p_token_id
    AND owner_id = auth.uid()
    AND revoked_at IS NULL;

  GET DIAGNOSTICS v_revoked = ROW_COUNT;
  IF NOT v_revoked THEN
    RETURN; -- not the caller's token, or already revoked — do nothing else
  END IF;

  -- Cut existing agent access: remove every non-owner member from the caller's
  -- chats that were bound with this token. The owner (auth.uid()) stays; the
  -- reassign_admin_on_leave trigger promotes them to admin.
  DELETE FROM chat_members
  WHERE user_id <> auth.uid()
    AND chat_id IN (
      SELECT id FROM chats
      WHERE mcp_token_id = p_token_id
        AND mcp_owner_id = auth.uid()
    );

  -- Also clear any not-yet-approved agent join requests on those chats.
  DELETE FROM pending_chat_members
  WHERE user_id <> auth.uid()
    AND chat_id IN (
      SELECT id FROM chats
      WHERE mcp_token_id = p_token_id
        AND mcp_owner_id = auth.uid()
    );
END;
$$;

COMMENT ON FUNCTION revoke_mcp_token IS 'Revokes one of the caller''s own MCP tokens AND removes agent members (every non-owner) from chats bound with that token — cutting existing MCP access, not just future binds (migration 00041).';

NOTIFY pgrst, 'reload schema';
