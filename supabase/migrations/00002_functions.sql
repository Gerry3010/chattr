-- ============================================================================
-- Database Functions
-- ============================================================================
-- This migration creates all functions used by the application including:
-- - Helper functions for RLS policies
-- - Chat metadata retrieval
-- - System message insertion
-- - Message cleanup
-- ============================================================================

-- Enable HTTP extension for Edge Function calls
CREATE EXTENSION IF NOT EXISTS http WITH SCHEMA extensions;

-- ============================================================================
-- PART 1: Helper Functions for RLS
-- ============================================================================

-- Check if a user is a member of a chat (bypasses RLS to avoid recursion)
CREATE OR REPLACE FUNCTION is_chat_member(p_chat_id UUID, p_user_id UUID)
RETURNS BOOLEAN
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM chat_members
    WHERE chat_id = p_chat_id
    AND user_id = p_user_id
  );
END;
$$;

COMMENT ON FUNCTION is_chat_member IS 'Check if a user is a member of a chat (bypasses RLS to avoid recursion)';

-- Check if a user is an admin of a chat
CREATE OR REPLACE FUNCTION is_chat_admin(chat_id_param UUID, user_id_param UUID)
RETURNS BOOLEAN
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM chats
    WHERE id = chat_id_param
    AND user_id_param = ANY(admins)
  );
END;
$$;

COMMENT ON FUNCTION is_chat_admin IS 'Check if a user is an admin of a specific chat';

-- ============================================================================
-- PART 2: Chat Metadata Function
-- ============================================================================

-- Get user chats with metadata (unread count, last message timestamp)
CREATE OR REPLACE FUNCTION get_user_chats_with_metadata(p_chat_ids UUID[] DEFAULT NULL)
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
LANGUAGE plpgsql
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
$$;

COMMENT ON FUNCTION get_user_chats_with_metadata IS 'Fetches user chats with unread count and last message timestamp. Uses auth.uid() for current user. Optionally filters by specific chat IDs. Includes updated_at.';

-- ============================================================================
-- PART 3: System Message Insertion
-- ============================================================================

-- Insert system message by calling Edge Function for encryption
CREATE OR REPLACE FUNCTION insert_system_message(
  p_chat_id UUID,
  p_action TEXT,
  p_subject_id UUID,
  p_subject_name TEXT
)
RETURNS VOID
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
DECLARE
  function_url TEXT;
  response TEXT;
BEGIN
  -- Get Edge Function URL
  function_url := COALESCE(
    current_setting('app.settings.edge_function_url', true),
    'http://kong:8000/functions/v1/insert-system-message'
  );

  -- Call Edge Function to encrypt and insert the message
  BEGIN
    SELECT "content"::jsonb
    INTO response
    FROM extensions.http((
      'POST',
      function_url,
      ARRAY[extensions.http_header('Authorization', 'Bearer ' || private.get_secret('service_role_key'))],
      'application/json',
      jsonb_build_object(
        'chat_id', p_chat_id::text,
        'action', p_action,
        'subject_id', p_subject_id::text,
        'subject_name', p_subject_name
      )::text
    ));
  EXCEPTION WHEN OTHERS THEN
    -- Log error but don't fail the trigger
    RAISE WARNING 'Failed to call insert-system-message Edge Function: %', SQLERRM;
  END;
END;
$$;

COMMENT ON FUNCTION insert_system_message IS 'Calls Edge Function to encrypt and insert system message with JSON structure {action, subject_id, subject_name}';

-- ============================================================================
-- PART 4: Message Cleanup Function
-- ============================================================================

-- Clean up old messages
CREATE OR REPLACE FUNCTION cleanup_old_messages()
RETURNS INTEGER
SECURITY DEFINER
LANGUAGE plpgsql
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
$$;

COMMENT ON FUNCTION cleanup_old_messages IS 'Deletes read messages older than 7 days and unread/unreceived messages older than 30 days';

-- ============================================================================
-- PART 5: Message Status Update Functions
-- ============================================================================

-- Mark message as received and clear encrypted content
CREATE OR REPLACE FUNCTION mark_message_received(
  p_message_id UUID,
  p_chat_id UUID
)
RETURNS VOID
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
BEGIN
  -- Update the message for the current user (recipient)
  UPDATE messages
  SET 
    received_at = NOW(),
    encrypted_content = ''
  WHERE id = p_message_id
    AND chat_id = p_chat_id
    AND recipient_id = auth.uid()
    AND received_at IS NULL;  -- Only mark if not already received
    
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Message not found or already received';
  END IF;
END;
$$;

COMMENT ON FUNCTION mark_message_received IS 'Marks a message as received for the current user and clears encrypted content. Can only be called by the recipient.';

-- Mark message as read and clear encrypted content
CREATE OR REPLACE FUNCTION mark_message_read(
  p_message_id UUID,
  p_chat_id UUID
)
RETURNS VOID
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
BEGIN
  -- Update the message for the current user (recipient)
  UPDATE messages
  SET 
    read_at = NOW(),
    encrypted_content = ''
  WHERE id = p_message_id
    AND chat_id = p_chat_id
    AND recipient_id = auth.uid()
    AND read_at IS NULL;  -- Only mark if not already read
    
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Message not found or already read';
  END IF;
END;
$$;

COMMENT ON FUNCTION mark_message_read IS 'Marks a message as read for the current user and clears encrypted content. Can only be called by the recipient.';

-- ============================================================================
-- PART 6: Trigger Helper Functions
-- ============================================================================

-- Set creator as admin when chat is created
CREATE OR REPLACE FUNCTION set_creator_as_admin()
RETURNS TRIGGER
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
BEGIN
  -- Set created_by to current user
  NEW.created_by := auth.uid();
  -- Set the creator as the first admin
  NEW.admins := ARRAY[auth.uid()];
  RETURN NEW;
END;
$$;

-- Automatically update updated_at timestamp for chats
CREATE OR REPLACE FUNCTION update_chats_updated_at()
RETURNS TRIGGER
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION update_chats_updated_at IS 'Automatically updates the updated_at column when a chat is modified';

-- Generic function to update updated_at column
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION update_updated_at_column IS 'Automatically updates the updated_at column to the current timestamp';

-- Automatically update updated_at timestamp for messages
CREATE OR REPLACE FUNCTION update_messages_updated_at()
RETURNS TRIGGER
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION update_messages_updated_at IS 'Automatically updates updated_at column on message updates';

-- Automatically update updated_at timestamp for pending members
CREATE OR REPLACE FUNCTION update_pending_members_updated_at()
RETURNS TRIGGER
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

-- Reassign admin when an admin leaves a chat
CREATE OR REPLACE FUNCTION reassign_admin_on_leave()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  chat_record RECORD;
  remaining_member UUID;
BEGIN
  -- Get the chat
  SELECT * INTO chat_record FROM chats WHERE id = OLD.chat_id;
  
  -- Check if the leaving user was an admin
  IF OLD.user_id = ANY(chat_record.admins) THEN
    -- Remove the leaving user from the admins array
    UPDATE chats 
    SET admins = array_remove(admins, OLD.user_id)
    WHERE id = OLD.chat_id;
    
    -- Check if there are no admins left
    IF (SELECT array_length(array_remove(chat_record.admins, OLD.user_id), 1) IS NULL 
        OR array_length(array_remove(chat_record.admins, OLD.user_id), 1) = 0) THEN
      -- Select a random remaining member to be admin
      SELECT user_id INTO remaining_member
      FROM chat_members
      WHERE chat_id = OLD.chat_id
      AND user_id != OLD.user_id
      ORDER BY RANDOM()
      LIMIT 1;
      
      -- If there's a remaining member, make them admin
      IF remaining_member IS NOT NULL THEN
        UPDATE chats
        SET admins = array_append(admins, remaining_member)
        WHERE id = OLD.chat_id;
      -- If there are no remaining members, delete the chat
      ELSE
        DELETE FROM chats WHERE id = OLD.chat_id;
      END IF;
    END IF;
  END IF;
  
  RETURN OLD;
END;
$$;
