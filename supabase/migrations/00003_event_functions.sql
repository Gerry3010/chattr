-- ============================================================================
-- Event Notification Functions
-- ============================================================================
-- This migration creates all functions for realtime events and push
-- notifications including:
-- - New message notifications
-- - Chat membership changes
-- - Pending member notifications
-- - Chat updates and deletions
-- - Message status updates
-- ============================================================================

-- ============================================================================
-- PART 1: Vault Secret Access (for service_role_key)
-- ============================================================================

-- Create private schema (not exposed in API)
CREATE SCHEMA IF NOT EXISTS private;

COMMENT ON SCHEMA private IS 'Schema for internal functions not exposed via PostgREST API';

-- Create function to retrieve secrets from Vault
CREATE OR REPLACE FUNCTION private.get_secret(secret_name TEXT)
RETURNS TEXT
SECURITY DEFINER
SET search_path = ''
LANGUAGE plpgsql
AS $$
DECLARE
  secret TEXT;
BEGIN
  SELECT decrypted_secret INTO secret 
  FROM vault.decrypted_secrets 
  WHERE name = secret_name;
  
  RETURN secret;
END;
$$;

COMMENT ON FUNCTION private.get_secret IS 'Retrieves a decrypted secret from vault.decrypted_secrets by name. Used by database functions to access sensitive configuration like service_role_key.';

-- Grant execute permission to postgres and service_role
GRANT EXECUTE ON FUNCTION private.get_secret(TEXT) TO postgres, service_role;

-- ============================================================================
-- PART 2: New Message Notifications
-- ============================================================================

-- Notify recipient of new message via realtime and push notification
CREATE OR REPLACE FUNCTION notify_members_new_message()
RETURNS TRIGGER
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
DECLARE
  chat_name TEXT;
  sender_name TEXT;
  function_url TEXT;
BEGIN
  -- Only notify if there's a recipient_id
  IF NEW.recipient_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- Get chat name
  SELECT name INTO chat_name
  FROM chats
  WHERE id = NEW.chat_id;

  -- Get sender username
  SELECT username INTO sender_name
  FROM profiles
  WHERE id = NEW.sender_id;

  -- Set defaults if values are null
  chat_name := COALESCE(chat_name, 'Chat');
  sender_name := COALESCE(sender_name, 'Someone');

  -- Send realtime event to the specific recipient
  PERFORM realtime.send(
    jsonb_build_object(
      'type', 'newMessage',
      'chat_id', NEW.chat_id,
      'message_id', NEW.id,
      'sender_id', NEW.sender_id,
      'content', NEW.encrypted_content,
      'message_type', NEW.message_type,
      'timestamp', NOW()
    ),
    'event',
    'user:' || NEW.recipient_id::text,
    FALSE
  );

  -- Send push notification if not system message
  IF NEW.message_type != 'system' THEN
    function_url := COALESCE(
      current_setting('app.settings.edge_function_url', true),
      'http://kong:8000/functions/v1/send-push-notification'
    );

    BEGIN
      PERFORM net.http_post(
        url := function_url,
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'Authorization', 'Bearer ' || private.get_secret('service_role_key')
        ),
        body := jsonb_build_object(
          'type', 'new_message',
          'user_ids', ARRAY[NEW.recipient_id],
          'title', chat_name,
          'body', 'Neue Nachricht von ' || sender_name,
          'data', jsonb_build_object(
            'chat_id', NEW.chat_id::text,
            'message_id', NEW.id::text,
            'sender_name', sender_name
          )
        )
      );
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Failed to send push notification: %', SQLERRM;
    END;
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION notify_members_new_message IS 'Notifies recipient via realtime and push notification - uses vault for service_role_key';

-- ============================================================================
-- PART 3: Chat Membership Change Notifications
-- ============================================================================

-- Broadcast newChat event when a member is added
CREATE OR REPLACE FUNCTION broadcast_new_chat_member()
RETURNS TRIGGER
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
BEGIN
  -- Notify the new member about the chat they were added to
  PERFORM realtime.send(
    jsonb_build_object(
      'type', 'newChat',
      'chat_id', NEW.chat_id,
      'timestamp', NOW()
    ),
    'event',
    'user:' || NEW.user_id::text,
    FALSE
  );
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION broadcast_new_chat_member IS 'Broadcasts a newChat event to the user when they are added to a chat';

-- Notify members about membership changes (joined/left)
CREATE OR REPLACE FUNCTION notify_membership_change()
RETURNS TRIGGER
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
DECLARE
  changed_user_id UUID;
  action TEXT;
  member_record RECORD;
  username_text TEXT;
BEGIN
  -- Determine action and affected user
  IF TG_OP = 'INSERT' THEN
    changed_user_id := NEW.user_id;
    action := 'joined';
  ELSIF TG_OP = 'DELETE' THEN
    changed_user_id := OLD.user_id;
    action := 'left';
  ELSE
    -- For UPDATE, we don't track anymore
    RETURN NEW;
  END IF;

  -- Get username for system message
  SELECT username INTO username_text
  FROM profiles
  WHERE id = changed_user_id;
  
  username_text := COALESCE(username_text, 'A user');

  -- Insert encrypted system message for all members
  PERFORM insert_system_message(
    COALESCE(NEW.chat_id, OLD.chat_id),
    action,
    changed_user_id,
    username_text
  );

  -- Notify all members of this chat (except the changed user)
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
$$;

COMMENT ON FUNCTION notify_membership_change IS 'Notifies members about membership changes (joined/left) and creates system messages';

-- ============================================================================
-- PART 4: Pending Member Notifications
-- ============================================================================

-- Notify admins when a user requests to join
CREATE OR REPLACE FUNCTION notify_admins_pending_member()
RETURNS TRIGGER
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
DECLARE
  admin_id TEXT;
  chat_admins TEXT[];
  chat_name TEXT;
  requester_name TEXT;
  admin_uuids UUID[];
  function_url TEXT;
BEGIN
  -- Get the list of admins for this chat
  SELECT admins INTO chat_admins
  FROM chats
  WHERE id = NEW.chat_id;

  -- Get chat name and requester username
  SELECT name INTO chat_name FROM chats WHERE id = NEW.chat_id;
  SELECT username INTO requester_name FROM profiles WHERE id = NEW.user_id;
  
  chat_name := COALESCE(chat_name, 'Chat');
  requester_name := COALESCE(requester_name, 'Someone');

  -- Send realtime notifications to each admin
  IF chat_admins IS NOT NULL THEN
    FOREACH admin_id IN ARRAY chat_admins
    LOOP
      PERFORM realtime.send(
        jsonb_build_object(
          'type', 'pendingMember',
          'chat_id', NEW.chat_id,
          'user_id', NEW.user_id,
          'timestamp', NOW()
        ),
        'event',
        'user:' || admin_id,
        FALSE
      );
    END LOOP;

    -- Convert TEXT[] to UUID[] for push notifications
    admin_uuids := (
      SELECT ARRAY_AGG(aid::UUID)
      FROM unnest(chat_admins) AS aid
    );

    -- Send push notifications
    IF admin_uuids IS NOT NULL AND array_length(admin_uuids, 1) > 0 THEN
      function_url := COALESCE(
        current_setting('app.settings.edge_function_url', true),
        'http://kong:8000/functions/v1/send-push-notification'
      );

      BEGIN
        PERFORM net.http_post(
          url := function_url,
          headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'Authorization', 'Bearer ' || private.get_secret('service_role_key')
          ),
          body := jsonb_build_object(
            'type', 'member_request',
            'user_ids', admin_uuids,
            'title', 'New Join Request',
            'body', requester_name || ' wants to join ' || chat_name,
            'data', jsonb_build_object(
              'chat_id', NEW.chat_id::text,
              'requester_id', NEW.user_id::text,
              'requester_name', requester_name
            )
          )
        );
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'Failed to send push notification: %', SQLERRM;
      END;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION notify_admins_pending_member IS 'Notifies admins when a user requests to join via pending_chat_members';

-- ============================================================================
-- PART 5: Chat Update Notifications
-- ============================================================================

-- Notify members when chat metadata changes
CREATE OR REPLACE FUNCTION notify_chat_update()
RETURNS TRIGGER
SECURITY DEFINER
LANGUAGE plpgsql
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
    -- Notify all members of this chat
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
$$;

COMMENT ON FUNCTION notify_chat_update IS 'Notifies members when chat metadata (name, admins) changes';

-- ============================================================================
-- PART 6: Chat Deletion Notifications
-- ============================================================================

-- Notify all members when a chat is deleted
CREATE OR REPLACE FUNCTION notify_chat_delete()
RETURNS TRIGGER
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
DECLARE
  member_record RECORD;
BEGIN
  -- Notify all members of this chat
  FOR member_record IN
    SELECT user_id
    FROM chat_members
    WHERE chat_id = OLD.id
  LOOP
    PERFORM realtime.send(
      jsonb_build_object(
        'type', 'chatDeleted',
        'chat_id', OLD.id,
        'timestamp', NOW()
      ),
      'event',
      'user:' || member_record.user_id,
      FALSE
    );
  END LOOP;
  
  RETURN OLD;
END;
$$;

COMMENT ON FUNCTION notify_chat_delete IS 'Notifies all members when a chat is deleted';

-- Notify user when they are removed from a chat
CREATE OR REPLACE FUNCTION notify_chat_deleted_on_member_removal()
RETURNS TRIGGER
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
BEGIN
  -- Send chatDeleted event to the removed user
  PERFORM realtime.send(
    jsonb_build_object(
      'type', 'chatDeleted',
      'chat_id', OLD.chat_id,
      'timestamp', NOW()
    ),
    'event',
    'user:' || OLD.user_id,
    FALSE
  );
  
  RETURN OLD;
END;
$$;

COMMENT ON FUNCTION notify_chat_deleted_on_member_removal IS 'Notifies a user via chatDeleted event when they are removed from a chat';

-- ============================================================================
-- PART 7: Message Update/Delete Notifications
-- ============================================================================

-- Notify sender when message status changes
CREATE OR REPLACE FUNCTION notify_message_update()
RETURNS TRIGGER
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
DECLARE
  updates_json JSONB;
BEGIN
  -- Build updates object with only changed fields
  updates_json := jsonb_build_object();
  
  IF OLD.received_at IS DISTINCT FROM NEW.received_at THEN
    updates_json := updates_json || jsonb_build_object('received_at', NEW.received_at);
  END IF;
  
  IF OLD.read_at IS DISTINCT FROM NEW.read_at THEN
    updates_json := updates_json || jsonb_build_object('read_at', NEW.read_at);
  END IF;
  
  -- Only notify if something relevant changed and if there's a sender
  IF updates_json != '{}'::jsonb AND NEW.sender_id IS NOT NULL THEN
    -- Notify the sender about status change
    PERFORM realtime.send(
      jsonb_build_object(
        'type', 'messageUpdate',
        'chat_id', NEW.chat_id,
        'message_id', NEW.id,
        'recipient_id', NEW.recipient_id,
        'updates', updates_json,
        'timestamp', NOW()
      ),
      'event',
      'user:' || NEW.sender_id,
      FALSE
    );
  END IF;
  
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION notify_message_update IS 'Notifies sender when message status changes (received/read)';

-- Notify members when a message is deleted
CREATE OR REPLACE FUNCTION notify_message_delete()
RETURNS TRIGGER
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
DECLARE
  member_record RECORD;
BEGIN
  -- Notify all members of this chat (except sender)
  FOR member_record IN
    SELECT user_id
    FROM chat_members
    WHERE chat_id = OLD.chat_id
      AND user_id != OLD.sender_id
  LOOP
    PERFORM realtime.send(
      jsonb_build_object(
        'type', 'messageDelete',
        'chat_id', OLD.chat_id,
        'message_id', OLD.id,
        'timestamp', NOW()
      ),
      'event',
      'user:' || member_record.user_id,
      FALSE
    );
  END LOOP;
  
  RETURN OLD;
END;
$$;

COMMENT ON FUNCTION notify_message_delete IS 'Notifies all members (except sender) when a message is deleted';
