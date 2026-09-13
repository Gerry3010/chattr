-- ============================================================================
-- 00039: MCP owner auto-approve
-- ----------------------------------------------------------------------------
-- When the human owner of an MCP chat (chats.mcp_owner_id, set server-side from
-- a verified token by bind_mcp_chat, migration 00038) files a join request into
-- pending_chat_members, promote them to a full member immediately instead of
-- leaving them in the admin approval queue.
--
-- Why this is safe (and not the spoofable username heuristic we deliberately
-- avoided): mcp_owner_id is stamped by bind_mcp_chat purely from the SHA-256 of
-- the owner's minted token — a client can never set it. So "pending.user_id ==
-- chats.mcp_owner_id" provably means the owner's own account, nobody else's.
--
-- Ordering makes this a clean insert-time promotion: ensureProjectChat binds the
-- chat (sets mcp_owner_id) BEFORE the owner's app ever discovers it, and the
-- owner's McpAutoJoinController files its pending row WITH the E2E public_key it
-- generated (pending_chat_members.public_key is NOT NULL). So at INSERT time we
-- already have both the owner match and the key needed for chat_members.
--
-- A SECURITY DEFINER trigger bypasses RLS (the owner is NOT a chat admin, so it
-- couldn't self-insert into chat_members otherwise). The downstream chat_members
-- INSERT triggers (broadcast_new_chat_member, notify_membership_change from
-- 00004) fire for free, so the Realtime membership event + "joined" system
-- message happen exactly as for a normal approval.
-- ============================================================================

CREATE OR REPLACE FUNCTION auto_approve_mcp_owner()
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
     ) THEN
    -- Promote with the SAME public_key the owner submitted (E2E identity).
    INSERT INTO chat_members (chat_id, user_id, public_key)
      VALUES (NEW.chat_id, NEW.user_id, NEW.public_key)
      ON CONFLICT DO NOTHING;

    -- Clear the now-redundant pending row (idempotent with any app-side retry).
    DELETE FROM pending_chat_members
      WHERE chat_id = NEW.chat_id AND user_id = NEW.user_id;
  END IF;

  RETURN NULL; -- AFTER trigger; return value is ignored
END;
$$;

COMMENT ON FUNCTION auto_approve_mcp_owner IS 'Auto-approves the MCP chat owner''s own join request (pending.user_id = chats.mcp_owner_id) so they are never stuck in the pending queue. Owner identity is server-verified via bind_mcp_chat, not client-claimed.';

DROP TRIGGER IF EXISTS auto_approve_mcp_owner_trigger ON pending_chat_members;
CREATE TRIGGER auto_approve_mcp_owner_trigger
AFTER INSERT ON pending_chat_members
FOR EACH ROW
EXECUTE FUNCTION auto_approve_mcp_owner();

COMMENT ON TRIGGER auto_approve_mcp_owner_trigger ON pending_chat_members IS 'Promotes the bound MCP owner straight to member on their join request (see auto_approve_mcp_owner).';

NOTIFY pgrst, 'reload schema';
