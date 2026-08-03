-- Refactor event bus and add encrypted system messages
-- 1. Standardize event field naming to snake_case
-- 2. Consolidate member events (memberAdded/memberRemoved) into membershipChanged
-- 3. Add helper function to create encrypted system messages
-- 4. Update membership triggers to create system messages

-- =============================================================================
-- PART 1: Helper function to insert encrypted system messages
-- =============================================================================

-- enable the "http" extension
create extension http with schema extensions;

-- Function to encrypt and insert a system message for all chat members
-- Calls Edge Function for RSA encryption since pgcrypto doesn't support modern RSA
CREATE OR REPLACE FUNCTION insert_system_message(
  p_chat_id UUID,
  p_content TEXT,
  p_action TEXT DEFAULT NULL
)
RETURNS TEXT
SECURITY DEFINER
AS $$
DECLARE
  function_url TEXT;
  response TEXT;
BEGIN

  -- Get Edge Function URL
  function_url := COALESCE(
    current_setting('app.settings.edge_function_url', true),
    --'http://kong:8000/functions/v1/insert-system-message'
    'http://kong:8000/functions/v1/insert-system-message'
  );

  -- Call Edge Function to encrypt and insert message
  BEGIN
    SELECT
    "content"::jsonb
    INTO response
    FROM
    extensions.http((
      'POST',
      function_url,
      ARRAY[extensions.http_header('Authorization', 'Bearer ' || current_setting('app.settings.service_role_key', true))],
      'application/json',
      jsonb_build_object(
        'chat_id', p_chat_id::text,
        'content', p_content,
        'action', p_action
      )::text
    )
    );
    return response;
  EXCEPTION WHEN OTHERS THEN
    -- Log error but don't fail the trigger
    RAISE exception 'Failed to call insert-system-message Edge Function: %', SQLERRM;
  END;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION insert_system_message IS 'Calls Edge Function to encrypt and insert system message for all accepted members';
-- =============================================================================
-- PART 2: Update all triggers to use snake_case and include timestamp
-- =============================================================================

-- 2a. Update newMessage trigger (already snake_case, ensure timestamp)
CREATE OR REPLACE FUNCTION notify_members_new_message()
RETURNS TRIGGER
SECURITY DEFINER
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
      'timestamp', NOW()
    ),
    'event',
    'user:' || NEW.recipient_id::text,
    FALSE
  );

  -- Send push notification
  function_url := COALESCE(
    current_setting('app.settings.edge_function_url', true),
    'http://kong:8000/functions/v1/send-push-notification'
  );

  BEGIN
    PERFORM net.http_post(
      url := function_url,
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || current_setting('app.settings.service_role_key', true)
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

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 2b. Update newChat trigger (already snake_case, ensure timestamp)
CREATE OR REPLACE FUNCTION broadcast_new_chat_member()
RETURNS TRIGGER
SECURITY DEFINER
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
$$ LANGUAGE plpgsql;

-- 2c. Update pendingMember trigger (already snake_case, ensure timestamp)
CREATE OR REPLACE FUNCTION notify_admins_pending_member()
RETURNS TRIGGER
SECURITY DEFINER
AS $$
DECLARE
  admin_id TEXT;
  chat_admins TEXT[];
  chat_name TEXT;
  requester_name TEXT;
  admin_uuids UUID[];
  function_url TEXT;
BEGIN
  -- Only notify if the member is not yet accepted (pending)
  IF NEW.accepted = FALSE THEN
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
        SELECT ARRAY_AGG(aid::uuid)
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
              'Authorization', 'Bearer ' || current_setting('app.settings.service_role_key', true)
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
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 2d. Update memberStatusChanged trigger (change to snake_case)
CREATE OR REPLACE FUNCTION notify_member_status_change()
RETURNS TRIGGER
SECURITY DEFINER
AS $$
DECLARE
  old_accepted boolean := COALESCE(OLD.accepted, false);
  new_accepted boolean := COALESCE(NEW.accepted, false);
BEGIN
  -- Only notify if accepted status actually changed
  IF old_accepted IS DISTINCT FROM new_accepted THEN
    PERFORM realtime.send(
      jsonb_build_object(
        'type', 'memberStatusChanged',
        'chat_id', NEW.chat_id,
        'user_id', NEW.user_id,
        'accepted', NEW.accepted,
        'timestamp', NOW()
      ),
      'event',
      'user:' || NEW.user_id,
      FALSE
    );
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- PART 3: Consolidate and update membershipChanged trigger with system messages
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
    -- For UPDATE, only care about acceptance status changes
    IF OLD.accepted = false AND NEW.accepted = true THEN
      changed_user_id := NEW.user_id;
      action := 'approved';
    ELSE
      RETURN NEW; -- No relevant change
    END IF;
  END IF;

  -- Get username for system message
  SELECT username INTO username_text
  FROM profiles
  WHERE id = changed_user_id;
  
  username_text := COALESCE(username_text, 'A user');

  -- Create appropriate system message
  CASE action
    WHEN 'joined' THEN
      system_message := username_text || ' joined the chat';
    WHEN 'left' THEN
      system_message := username_text || ' left the chat';
    WHEN 'approved' THEN
      system_message := username_text || ' was approved to join';
    ELSE
      system_message := username_text || ' ' || action;
  END CASE;

  -- Insert encrypted system message for all members
  PERFORM insert_system_message(
    COALESCE(NEW.chat_id, OLD.chat_id),
    system_message,
    action
  );

  -- Notify all ACCEPTED members of this chat (except the changed user)
  FOR member_record IN
    SELECT user_id
    FROM chat_members
    WHERE chat_id = COALESCE(NEW.chat_id, OLD.chat_id)
      AND accepted = true
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

COMMENT ON FUNCTION notify_membership_change IS 'Notifies members about membership changes (joined/left/approved) and creates system messages';

-- =============================================================================
-- PART 4: Add triggers for chat and message updates/deletes
-- =============================================================================

-- 4a. Chat update trigger (fires on name or admins changes)
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
    -- Notify all accepted members of this chat
    FOR member_record IN
      SELECT user_id
      FROM chat_members
      WHERE chat_id = NEW.id
        AND accepted = true
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

DROP TRIGGER IF EXISTS chat_update_trigger ON chats;
CREATE TRIGGER chat_update_trigger
AFTER UPDATE ON chats
FOR EACH ROW
EXECUTE FUNCTION notify_chat_update();

COMMENT ON FUNCTION notify_chat_update IS 'Notifies all members when chat name or admins are updated';

-- 4b. Chat delete trigger
CREATE OR REPLACE FUNCTION notify_chat_delete()
RETURNS TRIGGER
SECURITY DEFINER
AS $$
DECLARE
  member_record RECORD;
BEGIN
  -- Notify all accepted members of this chat
  FOR member_record IN
    SELECT user_id
    FROM chat_members
    WHERE chat_id = OLD.id
      AND accepted = true
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
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS chat_delete_trigger ON chats;
CREATE TRIGGER chat_delete_trigger
BEFORE DELETE ON chats
FOR EACH ROW
EXECUTE FUNCTION notify_chat_delete();

COMMENT ON FUNCTION notify_chat_delete IS 'Notifies all members when a chat is deleted';

-- 4c. Message update trigger (for status changes like received_at, read_at)
CREATE OR REPLACE FUNCTION notify_message_update()
RETURNS TRIGGER
SECURITY DEFINER
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
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS message_update_trigger ON messages;
CREATE TRIGGER message_update_trigger
AFTER UPDATE ON messages
FOR EACH ROW
EXECUTE FUNCTION notify_message_update();

COMMENT ON FUNCTION notify_message_update IS 'Notifies sender when message status changes (received/read)';

-- 4d. Message delete trigger
CREATE OR REPLACE FUNCTION notify_message_delete()
RETURNS TRIGGER
SECURITY DEFINER
AS $$
DECLARE
  member_record RECORD;
BEGIN
  -- Notify all accepted members of this chat (except sender)
  FOR member_record IN
    SELECT user_id
    FROM chat_members
    WHERE chat_id = OLD.chat_id
      AND accepted = true
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
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS message_delete_trigger ON messages;
CREATE TRIGGER message_delete_trigger
BEFORE DELETE ON messages
FOR EACH ROW
EXECUTE FUNCTION notify_message_delete();

COMMENT ON FUNCTION notify_message_delete IS 'Notifies all members (except sender) when a message is deleted';
