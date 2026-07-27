-- ============================================================================
-- 00044: MCP owner is ALWAYS the (sole) admin — prompt-injection defense
-- ----------------------------------------------------------------------------
-- Until now an MCP chat's only admin was the AGENT that created it (createChat
-- stamps admins = [creator]; bind_mcp_chat / auto_approve_mcp_owner never touch
-- admins). The human token owner joined only as a plain MEMBER. Consequences:
--   * The owner never received the pendingMember realtime broadcast or push,
--     and the admin overview (adminPendingRequestsProvider) filters to chats
--     where the viewer is an admin — so join requests to an MCP chat were
--     INVISIBLE to the owner. Only the agent could approve them.
--   * Worse, a prompt-injected agent — being the admin — could approve rogue
--     members or (with a second admin present) demote the owner.
--
-- Fix: the human owner must ALWAYS be the admin of a chat bound to them, and the
-- agent must NOT be. We make the owner the SOLE admin, both going forward (in
-- the auto-approve trigger, at the moment the owner joins) and for every MCP
-- chat that already exists (backfill below). The agent keeps its chat_members
-- row, so it can still send messages — it just loses admin control.
--
-- Safe because mcp_owner_id is server-verified by bind_mcp_chat (SHA-256 of the
-- owner's minted token), never client-claimed (see 00038/00039).
-- ============================================================================

-- PART 1: auto-approve now also makes the owner the sole admin -----------------
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

COMMENT ON FUNCTION auto_approve_mcp_owner IS 'Auto-approves the MCP chat owner''s own join request AND makes them the sole admin (demoting the agent) — owner identity is server-verified via bind_mcp_chat. The owner must always be admin so a prompt-injected agent cannot manage the chat.';

-- The trigger (00039) binds by function name, so replacing the function above is
-- enough — no trigger recreation needed.

-- PART 2: backfill every existing MCP chat -------------------------------------
-- Make the bound owner the sole admin of MCP chats that currently list someone
-- else (the agent). This immediately gives the owner control + request
-- visibility on chats bound before this migration (e.g. the sleep_app chat).
UPDATE chats
SET admins = ARRAY[mcp_owner_id]
WHERE is_mcp
  AND mcp_owner_id IS NOT NULL
  AND admins IS DISTINCT FROM ARRAY[mcp_owner_id];

NOTIFY pgrst, 'reload schema';
