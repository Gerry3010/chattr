-- Fix type mismatch: cast admins from UUID[] to TEXT[] in get_user_chats_with_metadata

CREATE OR REPLACE FUNCTION get_user_chats_with_metadata(p_user_id UUID)
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
    c.admins::TEXT[],  -- Cast UUID[] to TEXT[]
    c.is_group,
    -- Get timestamp of most recent message in this chat
    (
      SELECT MAX(m.created_at)
      FROM messages m
      WHERE m.chat_id = c.id
    ) AS last_message_at,
    -- Count unread messages (all messages not marked as read)
    (
      SELECT COUNT(*)
      FROM messages m
      WHERE m.chat_id = c.id
        AND m.recipient_id = p_user_id
        AND m.read_at IS NULL
    ) AS unread_count
  FROM chats c
  INNER JOIN chat_members cm ON cm.chat_id = c.id
  WHERE cm.user_id = p_user_id
    AND cm.accepted = true;
END;
$$ LANGUAGE plpgsql;