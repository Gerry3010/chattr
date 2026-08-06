-- ============================================================================
-- 00057: chat list last_message_at must include SENT messages
-- ----------------------------------------------------------------------------
-- get_user_chats_with_metadata derived last_message_at as
--     MAX(created_at) WHERE recipient_id = auth.uid()
-- i.e. from RECEIVED messages only. A message you SEND has rows with
-- recipient_id = <the other member>, sender_id = you — never recipient_id = you
-- — so the subquery ignored your own sends. Right after you wrote a chat, the
-- next chat-list refresh regressed last_message_at to your last INCOMING message,
-- pushing the chat back down and mislabelling it "yesterday" (visible once the
-- date label switched to calendar days). The client keeps a max(local, server)
-- guard, but the server value should be correct on its own (fresh install,
-- multi-device).
--
-- Fix: count both directions — recipient_id = auth.uid() OR sender_id = auth.uid().
-- unread_count stays recipient-only (you never have unread of your own sends).
--
-- Return type is unchanged, so CREATE OR REPLACE (no DROP) suffices.
-- ============================================================================

CREATE OR REPLACE FUNCTION get_user_chats_with_metadata(p_chat_ids uuid[] DEFAULT NULL::uuid[])
RETURNS TABLE(
  id uuid,
  created_at timestamptz,
  updated_at timestamptz,
  created_by uuid,
  name text,
  description text,
  avatar_path text,
  admins text[],
  is_group boolean,
  message_ttl_seconds integer,
  last_message_at timestamptz,
  unread_count bigint,
  is_mcp boolean,
  mcp_owner_id uuid
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN QUERY
  SELECT
    c.id,
    c.created_at,
    c.updated_at,
    c.created_by,
    c.name,
    c.description,
    c.avatar_path,
    c.admins::text[],
    c.is_group,
    c.message_ttl_seconds,
    (
      -- Latest activity in EITHER direction: messages I received OR sent.
      SELECT MAX(m.created_at)
      FROM messages m
      WHERE m.chat_id = c.id
        AND (m.recipient_id = auth.uid() OR m.sender_id = auth.uid())
    ) AS last_message_at,
    (
      -- Incoming messages newer than when I last opened this chat. Independent
      -- of read receipts: last_read_at is set by mark_chat_read() on open.
      SELECT COUNT(*)
      FROM messages m
      WHERE m.chat_id = c.id
        AND m.recipient_id = auth.uid()
        AND m.created_at > COALESCE(cm.last_read_at, '-infinity'::timestamptz)
    ) AS unread_count,
    c.is_mcp,
    c.mcp_owner_id
  FROM chats c
  INNER JOIN chat_members cm ON cm.chat_id = c.id
  WHERE cm.user_id = auth.uid()
    AND (p_chat_ids IS NULL OR c.id = ANY(p_chat_ids));
END;
$$;
