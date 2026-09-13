-- Migration: Add accepted status and timestamps to chat_members, add is_group to chats
-- This enables invitation acceptance workflow and better tracking

-- 1. Add new columns to chat_members
ALTER TABLE chat_members 
ADD COLUMN accepted BOOLEAN DEFAULT false NOT NULL,
ADD COLUMN created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
ADD COLUMN updated_at TIMESTAMPTZ DEFAULT NOW() NOT NULL;

COMMENT ON COLUMN chat_members.accepted IS 'Whether the member has accepted the invitation to join the chat';
COMMENT ON COLUMN chat_members.created_at IS 'When the member was added to the chat';
COMMENT ON COLUMN chat_members.updated_at IS 'When the member record was last updated';

-- 2. Add is_group column to chats
ALTER TABLE chats
ADD COLUMN is_group BOOLEAN DEFAULT true NOT NULL;

COMMENT ON COLUMN chats.is_group IS 'Whether this is a group chat (true) or a direct 1:1 chat (false)';

-- 3. Create function to automatically update updated_at timestamp
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION update_updated_at_column IS 'Automatically updates the updated_at column to the current timestamp';

-- 4. Create trigger to automatically update updated_at on chat_members
DROP TRIGGER IF EXISTS chat_members_updated_at_trigger ON chat_members;

CREATE TRIGGER chat_members_updated_at_trigger
BEFORE UPDATE ON chat_members
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

-- 5. Update existing chat_members to be accepted (backward compatibility)
UPDATE chat_members SET accepted = true WHERE accepted = false;

-- 6. Create RLS policies for chat_members
-- Policy 1: Only admins can update members (including accepted status)
DROP POLICY IF EXISTS "Admins can update chat members" ON chat_members;

CREATE POLICY "Admins can update chat members"
ON chat_members FOR UPDATE
USING (
  EXISTS (
    SELECT 1 FROM chats
    WHERE chats.id = chat_members.chat_id
    AND auth.uid() = ANY(chats.admins)
  )
);

COMMENT ON POLICY "Admins can update chat members" ON chat_members IS 'Only admins can update chat member fields (including accepted status)';

-- 7. Create index for faster queries on accepted status
CREATE INDEX IF NOT EXISTS idx_chat_members_accepted ON chat_members(chat_id, accepted);

-- 8. Update existing chats: Set is_group based on member count
UPDATE chats 
SET is_group = (
  SELECT COUNT(*) > 2 
  FROM chat_members 
  WHERE chat_members.chat_id = chats.id
)
WHERE is_group = true;
