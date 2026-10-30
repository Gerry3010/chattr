-- Migration: Add message status tracking (received_at, read_at) and deletion policies
-- Senders can delete unread messages, recipients can only update status columns

-- 1. Add status columns to messages table
ALTER TABLE messages
ADD COLUMN received_at TIMESTAMPTZ,
ADD COLUMN read_at TIMESTAMPTZ;

COMMENT ON COLUMN messages.received_at IS 'Timestamp when the recipient received/fetched the message from server';
COMMENT ON COLUMN messages.read_at IS 'Timestamp when the recipient read the message in the app';

-- 2. Create index for querying unread messages
CREATE INDEX idx_messages_unread ON messages (recipient_id, read_at) WHERE read_at IS NULL;

-- 3. Drop existing policies to recreate them with new permissions
DROP POLICY IF EXISTS "Users can read messages in their chats" ON messages;
DROP POLICY IF EXISTS "Users can insert messages in their chats" ON messages;
DROP POLICY IF EXISTS "Senders can update their messages" ON messages;
DROP POLICY IF EXISTS "Recipients can delete their messages" ON messages;

-- 4. Recreate read policy (unchanged)
CREATE POLICY "Users can read messages in their chats"
ON messages FOR SELECT
USING (
  recipient_id = auth.uid()
  OR sender_id = auth.uid()
);

-- 5. Recreate insert policy (unchanged)
CREATE POLICY "Users can insert messages in their chats"
ON messages FOR INSERT
WITH CHECK (
  sender_id = auth.uid()
  AND EXISTS (
    SELECT 1 FROM chat_members
    WHERE chat_members.chat_id = messages.chat_id
    AND chat_members.user_id = auth.uid()
  )
);

-- 6. NEW: Recipients can only update received_at and read_at columns
-- Note: We can't enforce "only these columns" in RLS, so we rely on application logic
-- and use a trigger to prevent unauthorized column updates
CREATE POLICY "Recipients can update message status"
ON messages FOR UPDATE
USING (recipient_id = auth.uid())
WITH CHECK (recipient_id = auth.uid());

-- 6b. Trigger to enforce that recipients can only update status columns
CREATE OR REPLACE FUNCTION check_message_update_columns()
RETURNS TRIGGER
SECURITY DEFINER
AS $$
BEGIN
  -- If the user is the recipient, only allow status column updates
  IF NEW.recipient_id = auth.uid() THEN
    -- Check if any non-status columns were modified
    IF NEW.id <> OLD.id
       OR NEW.chat_id <> OLD.chat_id
       OR NEW.sender_id <> OLD.sender_id
       OR NEW.recipient_id <> OLD.recipient_id
       OR NEW.encrypted_content IS DISTINCT FROM OLD.encrypted_content
       OR NEW.created_at <> OLD.created_at THEN
      RAISE EXCEPTION 'Recipients can only update received_at and read_at columns';
    END IF;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER enforce_message_update_columns
BEFORE UPDATE ON messages
FOR EACH ROW
EXECUTE FUNCTION check_message_update_columns();

-- 7. NEW: Senders can delete messages only if not yet read
CREATE POLICY "Senders can delete unread messages"
ON messages FOR DELETE
USING (
  sender_id = auth.uid()
  AND read_at IS NULL  -- Only allow deletion if message hasn't been read
);

COMMENT ON POLICY "Recipients can update message status" ON messages IS 'Recipients can only update received_at and read_at timestamps, nothing else';
COMMENT ON POLICY "Senders can delete unread messages" ON messages IS 'Senders can delete their messages only if they have not been read yet';
