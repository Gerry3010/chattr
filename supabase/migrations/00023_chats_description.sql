-- ============================================================================
-- 00023: Chat description / topic
-- ----------------------------------------------------------------------------
-- Adds an optional free-text description to chats and — same gotcha as 00017
-- for message_ttl_seconds — threads it through get_user_chats_with_metadata so
-- it actually reaches the client. Admins edit it from the chat-info screen.
-- (Assumes 00021/00022 from the delete-account change are already applied.)
-- ============================================================================

ALTER TABLE chats ADD COLUMN IF NOT EXISTS description TEXT;

COMMENT ON COLUMN chats.description IS 'Optional group description / topic (plaintext, non-sensitive metadata)';

DROP FUNCTION IF EXISTS get_user_chats_with_metadata(uuid[]);

CREATE OR REPLACE FUNCTION get_user_chats_with_metadata(p_chat_ids uuid[] DEFAULT NULL::uuid[])
RETURNS TABLE(
  id uuid,
  created_at timestamptz,
  updated_at timestamptz,
  created_by uuid,
  name text,
  description text,
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
    c.description,
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
