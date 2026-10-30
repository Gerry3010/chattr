-- Add updated_at column to messages table for better sync tracking
-- This column will be automatically updated on every row modification

-- Add the column with default value set to created_at
ALTER TABLE messages 
ADD COLUMN updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW();

-- Set initial values to match created_at for existing rows
UPDATE messages 
SET updated_at = created_at;

-- Create function to automatically update updated_at on row changes
CREATE OR REPLACE FUNCTION update_messages_updated_at()
RETURNS TRIGGER
SECURITY DEFINER
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create trigger to call the function before any update
DROP TRIGGER IF EXISTS messages_updated_at_trigger ON messages;
CREATE TRIGGER messages_updated_at_trigger
BEFORE UPDATE ON messages
FOR EACH ROW
EXECUTE FUNCTION update_messages_updated_at();

COMMENT ON COLUMN messages.updated_at IS 'Timestamp of last update, automatically maintained by trigger';
COMMENT ON FUNCTION update_messages_updated_at IS 'Automatically updates updated_at column on message updates';
