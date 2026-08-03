-- =====================================================
-- Add reply_to_sender_id to messages
-- =====================================================
-- This adds the sender_id of the original message being replied to

ALTER TABLE messages
ADD COLUMN reply_to_sender_id UUID;

COMMENT ON COLUMN messages.reply_to_sender_id IS 'ID of the sender of the replied-to message';
