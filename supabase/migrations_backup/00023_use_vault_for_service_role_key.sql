-- Update all triggers to use private.get_secret() for service_role_key
-- instead of current_setting('app.settings.service_role_key')

-- 1. Update insert_system_message function
-- Drop first because we're changing the return type
DROP FUNCTION IF EXISTS insert_system_message(UUID, TEXT, TEXT);

CREATE OR REPLACE FUNCTION insert_system_message(
  p_chat_id UUID,
  p_content TEXT,
  p_action TEXT DEFAULT NULL
)
RETURNS VOID
SECURITY DEFINER
AS $$
DECLARE
--  member_keys JSONB;
  function_url TEXT;
  response TEXT;
BEGIN
  -- Collect all member IDs and their public keys
--  SELECT jsonb_object_agg(
--    user_id::text,
--    public_key
--  ) INTO member_keys
--  FROM chat_members
--  WHERE chat_id = p_chat_id
--    AND accepted = true
--    AND public_key IS NOT NULL;
--
--  -- If no members with keys, nothing to do
--  IF member_keys IS NULL OR member_keys = '{}'::jsonb THEN
--    RETURN;
--  END IF;
  
  -- Get Edge Function URL
  function_url := COALESCE(
    current_setting('app.settings.edge_function_url', true),
    'http://kong:8000/functions/v1/insert-system-message'
  );
  
  -- Call Edge Function to encrypt and insert message
  BEGIN
--    SELECT * INTO response
--    FROM net.http_post(
--      url := function_url,
--      headers := jsonb_build_object(
--        'Content-Type', 'application/json',
--        'Authorization', 'Bearer ' || private.get_secret('service_role_key')
--      ),
--      body := jsonb_build_object(
--        'chat_id', p_chat_id::text,
--        'content', p_content,
--        'action', p_action,
--        'member_keys', member_keys
--      )
--    );
    SELECT
         "content"::jsonb
         INTO response
         FROM
         extensions.http((
           'POST',
           function_url,
           ARRAY[extensions.http_header('Authorization', 'Bearer ' || private.get_secret('service_role_key'))],
           'application/json',
           jsonb_build_object(
             'chat_id', p_chat_id::text,
             'content', p_content,
             'action', p_action
           )::text
         )
         );
  EXCEPTION WHEN OTHERS THEN
    -- Log error but don't fail the trigger
    RAISE WARNING 'Failed to call insert-system-message Edge Function: %', SQLERRM;
  END;
END;
$$ LANGUAGE plpgsql;

-- 2. Update notify_members_new_message function
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
$$ LANGUAGE plpgsql;

-- 3. Update notify_admins_pending_member function
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
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION insert_system_message IS 'Calls Edge Function to encrypt and insert system message - uses vault for service_role_key';
COMMENT ON FUNCTION notify_members_new_message IS 'Notifies recipient via realtime and push notification - uses vault for service_role_key';
COMMENT ON FUNCTION notify_admins_pending_member IS 'Notifies admins via realtime and push notifications - uses vault for service_role_key';
