-- Migration: Automatic cleanup of old messages
-- Deletes read messages after 7 days and unread/unreceived messages after 30 days

-- 1. Create cleanup function
CREATE OR REPLACE FUNCTION cleanup_old_messages()
RETURNS INTEGER
SECURITY DEFINER
AS $$
DECLARE
  deleted_read_count INTEGER;
  deleted_unread_count INTEGER;
  total_deleted INTEGER;
BEGIN
  -- Delete messages that have been read and are older than 7 days
  DELETE FROM messages
  WHERE read_at IS NOT NULL
    AND read_at < NOW() - INTERVAL '7 days';
  
  GET DIAGNOSTICS deleted_read_count = ROW_COUNT;
  
  -- Delete messages that haven't been received/read and are older than 30 days
  DELETE FROM messages
  WHERE received_at IS NULL
    AND created_at < NOW() - INTERVAL '30 days';
  
  GET DIAGNOSTICS deleted_unread_count = ROW_COUNT;
  
  total_deleted := deleted_read_count + deleted_unread_count;
  
  -- Log cleanup results
  RAISE NOTICE 'Message cleanup: deleted % read messages (>7 days) and % unread messages (>30 days). Total: %',
    deleted_read_count, deleted_unread_count, total_deleted;
  
  RETURN total_deleted;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION cleanup_old_messages IS 'Deletes read messages older than 7 days and unread/unreceived messages older than 30 days';

-- 2. Enable pg_cron extension (if not already enabled)
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- 3. Schedule the cleanup job to run daily at 3 AM
SELECT cron.schedule(
  'cleanup-old-messages',           -- job name
  '0 3 * * *',                       -- cron schedule: daily at 3 AM
  'SELECT cleanup_old_messages();'   -- SQL command
);

COMMENT ON EXTENSION pg_cron IS 'Enables scheduled job execution for automatic message cleanup';
