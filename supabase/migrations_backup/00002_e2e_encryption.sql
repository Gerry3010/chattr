-- Migration: End-to-End Encryption Support
-- Adds member_keys to chats table and restructures messages for encrypted content

-- 1. Add member_keys column to chats table
ALTER TABLE chats 
ADD COLUMN member_keys JSONB DEFAULT '{}'::jsonb;

COMMENT ON COLUMN chats.member_keys IS 'Map of userId to RSA public key (PEM format) for end-to-end encryption';

-- 2. Restructure messages table for encrypted content
-- Drop old content column and add new encryption columns
ALTER TABLE messages
DROP COLUMN IF EXISTS content;

ALTER TABLE messages
ADD COLUMN recipient_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
ADD COLUMN encrypted_content TEXT NOT NULL;

COMMENT ON COLUMN messages.recipient_id IS 'User ID this encrypted message copy is for';
COMMENT ON COLUMN messages.encrypted_content IS 'RSA-encrypted message content for the recipient';

-- 3. Create index for efficient message queries by recipient
CREATE INDEX IF NOT EXISTS idx_messages_recipient 
ON messages(chat_id, recipient_id, created_at DESC);

-- 4. Update RLS policies for new structure
-- Drop old policies if they exist
DROP POLICY IF EXISTS "Users can read messages in their chats" ON messages;
DROP POLICY IF EXISTS "Users can insert messages in their chats" ON messages;

-- Recreate policies for new schema
CREATE POLICY "Users can read their encrypted messages"
ON messages FOR SELECT
USING (
  recipient_id = auth.uid()
);

CREATE POLICY "Users can insert messages for all chat members"
ON messages FOR INSERT
WITH CHECK (
  sender_id = auth.uid() AND
  EXISTS (
    SELECT 1 FROM chat_members
    WHERE chat_members.chat_id = messages.chat_id
    AND chat_members.user_id = messages.recipient_id
  )
);

-- 5. Add policy for updating member_keys
DROP POLICY IF EXISTS "Users can update chats they are members of" ON chats;

CREATE POLICY "Members can update chat member_keys"
ON chats FOR UPDATE
USING (
  EXISTS (
    SELECT 1 FROM chat_members
    WHERE chat_members.chat_id = chats.id
    AND chat_members.user_id = auth.uid()
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1 FROM chat_members
    WHERE chat_members.chat_id = chats.id
    AND chat_members.user_id = auth.uid()
  )
);

-- 6. Create function to broadcast key exchange events
CREATE OR REPLACE FUNCTION broadcast_key_exchange()
RETURNS TRIGGER AS $$
DECLARE
  member_record RECORD;
BEGIN
  -- Notify all chat members about member_keys update
  FOR member_record IN 
    SELECT user_id FROM chat_members 
    WHERE chat_id = NEW.id
  LOOP
    PERFORM pg_notify(
      'user:' || member_record.user_id,
      json_build_object(
        'type', 'chatUpdate',
        'user_id', member_record.user_id,
        'chat_id', NEW.id,
        'updates', json_build_object('member_keys', NEW.member_keys),
        'timestamp', NOW()
      )::text
    );
  END LOOP;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create trigger for key exchange broadcasts
DROP TRIGGER IF EXISTS chat_key_exchange_trigger ON chats;

CREATE TRIGGER chat_key_exchange_trigger
AFTER UPDATE OF member_keys ON chats
FOR EACH ROW
WHEN (OLD.member_keys IS DISTINCT FROM NEW.member_keys)
EXECUTE FUNCTION broadcast_key_exchange();
