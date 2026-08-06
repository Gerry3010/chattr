-- ============================================================================
-- 00017: Expose message_ttl_seconds via get_user_chats_with_metadata
-- ----------------------------------------------------------------------------
-- Migration 00014 added chats.message_ttl_seconds but the RPC the client uses
-- to load chats (get_user_chats_with_metadata) wasn't updated, so the
-- disappearing-messages TTL never reached the app (the chat-detail card always
-- showed "Off"). Add the column to the function's result.
-- ============================================================================

DROP FUNCTION IF EXISTS get_user_chats_with_metadata(uuid[]);

CREATE OR REPLACE FUNCTION get_user_chats_with_metadata(p_chat_ids uuid[] DEFAULT NULL::uuid[])
RETURNS TABLE(
  id uuid,
  created_at timestamptz,
  updated_at timestamptz,
  created_by uuid,
  name text,
  admins text[],
  is_group boolean,
  message_ttl_seconds integer,
  last_message_at timestamptz,
  unread_count bigint
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
    c.admins::text[],
    c.is_group,
    c.message_ttl_seconds,
    (
      SELECT MAX(m.created_at)
      FROM messages m
      WHERE m.chat_id = c.id
        AND m.recipient_id = auth.uid()
    ) AS last_message_at,
    (
      SELECT COUNT(*)
      FROM messages m
      WHERE m.chat_id = c.id
        AND m.recipient_id = auth.uid()
        AND m.read_at IS NULL
    ) AS unread_count
  FROM chats c
  INNER JOIN chat_members cm ON cm.chat_id = c.id
  WHERE cm.user_id = auth.uid()
    AND (p_chat_ids IS NULL OR c.id = ANY(p_chat_ids));
END;
$$;
