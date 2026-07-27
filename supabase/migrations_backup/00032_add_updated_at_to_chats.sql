-- Add updated_at column to chats table with automatic trigger

-- Add the column
ALTER TABLE chats
ADD COLUMN updated_at TIMESTAMPTZ DEFAULT NOW() NOT NULL;

COMMENT ON COLUMN chats.updated_at IS 'Timestamp when the chat was last updated';

-- Create trigger function to automatically update updated_at
CREATE OR REPLACE FUNCTION update_chats_updated_at()
RETURNS TRIGGER
SECURITY DEFINER
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION update_chats_updated_at IS 'Automatically updates the updated_at column when a chat is modified';

-- Create trigger
DROP TRIGGER IF EXISTS chats_updated_at_trigger ON chats;

CREATE TRIGGER chats_updated_at_trigger
BEFORE UPDATE ON chats
FOR EACH ROW
EXECUTE FUNCTION update_chats_updated_at();

-- Set initial updated_at to created_at for existing chats
UPDATE chats SET updated_at = created_at WHERE updated_at IS NULL;

-- Update get_user_chats_with_metadata to include updated_at
DROP FUNCTION IF EXISTS get_user_chats_with_metadata(UUID[]);

CREATE OR REPLACE FUNCTION get_user_chats_with_metadata(
  p_chat_ids UUID[] DEFAULT NULL
)
RETURNS TABLE (
  id UUID,
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ,
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
    c.updated_at,
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

COMMENT ON FUNCTION get_user_chats_with_metadata IS 'Fetches user chats with unread count and last message timestamp. Uses auth.uid() for current user. Optionally filters by specific chat IDs. Includes updated_at.';
