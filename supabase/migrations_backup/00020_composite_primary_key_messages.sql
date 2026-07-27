-- Change messages table primary key to composite key (id, recipient_id)
-- This allows the same message ID to exist for multiple recipients
-- while maintaining uniqueness per recipient

-- 1. Drop the existing primary key constraint
ALTER TABLE messages
DROP CONSTRAINT messages_pkey;

-- 2. Remove the default UUID generation from id column
-- (since id will now be provided by the application for all recipient copies)
ALTER TABLE messages
ALTER COLUMN id DROP DEFAULT;

-- 3. Add the new composite primary key
ALTER TABLE messages
ADD PRIMARY KEY (id, recipient_id);

COMMENT ON CONSTRAINT messages_pkey ON messages IS 'Composite primary key allowing same message ID for different recipients';
COMMENT ON COLUMN messages.id IS 'Message ID shared across all recipient copies of the same logical message';