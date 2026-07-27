-- Fix all references to the removed 'accepted' column after membership refactoring
-- This migration updates all functions that still reference the old 'accepted' column

-- =============================================================================
-- PART 1: Remove the old trigger that references 'accepted'
-- =============================================================================

-- Drop the old trigger from migration 00011 that checks accepted status
DROP TRIGGER IF EXISTS on_member_status_change ON chat_members;

-- The notify_member_status_change function is no longer needed since
-- there's no 'accepted' status to track in chat_members anymore
-- (it's now tracked in pending_chat_members with blocked_at)

-- =============================================================================
-- PART 2: Update notify_membership_change to not reference 'accepted'
-- =============================================================================

CREATE OR REPLACE FUNCTION notify_membership_change()
RETURNS TRIGGER
SECURITY DEFINER
AS $$
DECLARE
  changed_user_id uuid;
  action text;
  member_record record;
  username_text text;
  system_message text;
BEGIN
  -- Determine action and affected user
  IF TG_OP = 'INSERT' THEN
    changed_user_id := NEW.user_id;
    action := 'joined';
  ELSIF TG_OP = 'DELETE' THEN
    changed_user_id := OLD.user_id;
    action := 'left';
  ELSE
    -- For UPDATE, we don't track acceptance anymore
    RETURN NEW;
  END IF;

  -- Get username for system message
  SELECT username INTO username_text
  FROM profiles
  WHERE id = changed_user_id;
  
  username_text := COALESCE(username_text, 'A user');

  -- Insert encrypted system message for all members
  -- Uses new signature: (chat_id, action, subject_id, subject_name)
  PERFORM insert_system_message(
    COALESCE(NEW.chat_id, OLD.chat_id),
    action,
    changed_user_id,
    username_text
  );

  -- Notify all members of this chat (except the changed user)
  -- No need to check 'accepted' since chat_members only contains accepted members now
  FOR member_record IN
    SELECT user_id
    FROM chat_members
    WHERE chat_id = COALESCE(NEW.chat_id, OLD.chat_id)
      AND user_id != changed_user_id
  LOOP
    PERFORM realtime.send(
      jsonb_build_object(
        'type', 'membershipChanged',
        'chat_id', COALESCE(NEW.chat_id, OLD.chat_id),
        'user_id', changed_user_id,
        'action', action,
        'timestamp', NOW()
      ),
      'event',
      'user:' || member_record.user_id,
      FALSE
    );
  END LOOP;

  RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION notify_membership_change IS 'Notifies members about membership changes (joined/left) and creates system messages';

-- =============================================================================
-- PART 3: Update get_user_chats_with_metadata to not reference 'accepted'
-- =============================================================================

CREATE OR REPLACE FUNCTION get_user_chats_with_metadata(p_user_id UUID)
RETURNS TABLE (
  id UUID,
  created_at TIMESTAMPTZ,
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
    c.created_by,
    c.name,
    c.admins::TEXT[],
    c.is_group,
    -- Get timestamp of most recent message in this chat
    (
      SELECT MAX(m.created_at)
      FROM messages m
      WHERE m.chat_id = c.id
      AND m.recipient_id = p_user_id
    ) AS last_message_at,
    -- Count unread messages (all messages not marked as read)
    (
      SELECT COUNT(*)
      FROM messages m
      WHERE m.chat_id = c.id
        AND m.recipient_id = p_user_id
        AND m.read_at IS NULL
    ) AS unread_count
  FROM chats c
  INNER JOIN chat_members cm ON cm.chat_id = c.id
  WHERE cm.user_id = p_user_id;
    -- No need to check 'accepted' anymore - chat_members only contains accepted members
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION get_user_chats_with_metadata IS 'Fetches user chats with unread count and last message timestamp for sorting';

-- =============================================================================
-- PART 4: Update notify_chat_update to not reference 'accepted'
-- =============================================================================

CREATE OR REPLACE FUNCTION notify_chat_update()
RETURNS TRIGGER
SECURITY DEFINER
AS $$
DECLARE
  member_record RECORD;
  updates_json JSONB;
BEGIN
  -- Build updates object with only changed fields
  updates_json := jsonb_build_object();
  
  IF OLD.name IS DISTINCT FROM NEW.name THEN
    updates_json := updates_json || jsonb_build_object('name', NEW.name);
  END IF;
  
  IF OLD.admins IS DISTINCT FROM NEW.admins THEN
    updates_json := updates_json || jsonb_build_object('admins', NEW.admins);
  END IF;
  
  -- Only notify if something actually changed
  IF updates_json != '{}'::jsonb THEN
    -- Notify all members of this chat (no need to check 'accepted')
    FOR member_record IN
      SELECT user_id
      FROM chat_members
      WHERE chat_id = NEW.id
    LOOP
      PERFORM realtime.send(
        jsonb_build_object(
          'type', 'chatUpdate',
          'chat_id', NEW.id,
          'updates', updates_json,
          'timestamp', NOW()
        ),
        'event',
        'user:' || member_record.user_id,
        FALSE
      );
    END LOOP;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION notify_chat_update IS 'Notifies members when chat metadata (name, admins) changes';
