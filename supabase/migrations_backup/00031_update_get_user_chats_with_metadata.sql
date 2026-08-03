-- Update get_user_chats_with_metadata to use auth.uid() and allow filtering by chat IDs
-- Changes:
-- 1. Remove p_user_id parameter in favor of auth.uid()
-- 2. Add optional p_chat_ids parameter to filter specific chats

-- Drop the old function
DROP FUNCTION IF EXISTS get_user_chats_with_metadata(UUID);

-- Create the updated function
CREATE OR REPLACE FUNCTION get_user_chats_with_metadata(
  p_chat_ids UUID[] DEFAULT NULL
)
RETURNS TABLE (
  id UUID,
  created_at TIMESTAMPTZ,
  created_by UUID,
  name TEXT,
  admins TEXT[],
  is_group BOOLEAN,
  last_message_at TIMESTAMPTZ,
  unread_count BIGINT
)
SECURITY DEFINER
AS $$
BEGIN
  RETURN QUERY
  SELECT 
    c.id,
    c.created_at,
    c.created_by,
    c.name,
    c.admins::TEXT[],
    c.is_group,
    -- Get timestamp of most recent message in this chat
    (
      SELECT MAX(m.created_at)
      FROM messages m
      WHERE m.chat_id = c.id
      AND m.recipient_id = auth.uid()
    ) AS last_message_at,
    -- Count unread messages (all messages not marked as read)
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
    -- Optionally filter by specific chat IDs
    AND (p_chat_ids IS NULL OR c.id = ANY(p_chat_ids));
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION get_user_chats_with_metadata IS 'Fetches user chats with unread count and last message timestamp. Uses auth.uid() for current user. Optionally filters by specific chat IDs.';
