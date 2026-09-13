-- =====================================================
-- Message Replies
-- =====================================================
-- This migration adds reply-to-message functionality

-- Add reply fields to messages table
-- Note: messages table has composite PK (id, recipient_id)
-- We only store the message ID for replies, not the specific recipient copy
ALTER TABLE messages
ADD COLUMN reply_to_message_id UUID,
ADD COLUMN reply_to_sender_name TEXT,
ADD COLUMN reply_to_preview TEXT;

-- Create index for better performance when loading messages with replies
CREATE INDEX IF NOT EXISTS idx_messages_reply_to ON messages(reply_to_message_id);

-- =====================================================
-- Comments
-- =====================================================

COMMENT ON COLUMN messages.reply_to_message_id IS 'References the message being replied to (nullable)';
COMMENT ON COLUMN messages.reply_to_sender_name IS 'Cached sender name of the replied-to message for UI display';
COMMENT ON COLUMN messages.reply_to_preview IS 'Encrypted preview text of the replied-to message (max 100 chars)';
