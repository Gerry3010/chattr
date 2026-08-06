-- Update triggers to send push notifications via Edge Function

-- 1. Update notify_members_new_message to also send push notifications
CREATE OR REPLACE FUNCTION notify_members_new_message()
RETURNS TRIGGER
SECURITY DEFINER
AS $$
DECLARE
  member_id TEXT;
  chat_members UUID[];
  chat_name TEXT;
  sender_name TEXT;
  function_url TEXT;
BEGIN
  -- Get all members of this chat who have accepted the invitation
  SELECT ARRAY_AGG(user_id) INTO chat_members
  FROM chat_members
  WHERE chat_id = NEW.chat_id
    AND user_id <> NEW.sender_id
    AND accepted = true;

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

  -- Notify each member via realtime (except the sender)
  IF chat_members IS NOT NULL THEN
    FOREACH member_id IN ARRAY chat_members
    LOOP
      -- Skip the sender to avoid self-notification
      IF member_id::uuid != NEW.sender_id THEN
        PERFORM realtime.send(
          json_build_object(
            'type', 'newMessage',
            'chat_id', NEW.chat_id,
            'message_id', NEW.id,
            'sender_id', NEW.sender_id,
            'content', NEW.encrypted_content,
            'timestamp', NEW.created_at
          )::jsonb,
          'event'::text,
          'user:' || member_id,
          FALSE
        );
      END IF;
    END LOOP;
  END IF;

  -- Send push notifications via Edge Function
  -- Remove sender from recipients
  chat_members := ARRAY_REMOVE(chat_members, NEW.sender_id);
  
  IF chat_members IS NOT NULL AND array_length(chat_members, 1) > 0 THEN
    -- Get the Edge Function URL from environment or use local default
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
          'user_ids', chat_members,
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
      -- Log error but don't fail the trigger
      RAISE WARNING 'Failed to send push notification: %', SQLERRM;
    END;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 2. Update notify_admins_pending_member to also send push notifications
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

    -- Get chat name
    SELECT name INTO chat_name
    FROM chats
    WHERE id = NEW.chat_id;

    -- Get requester username
    SELECT username INTO requester_name
    FROM profiles
    WHERE id = NEW.user_id;

    -- Set defaults
    chat_name := COALESCE(chat_name, 'Chat');
    requester_name := COALESCE(requester_name, 'Someone');

    -- Send realtime notifications to each admin
    IF chat_admins IS NOT NULL THEN
      FOREACH admin_id IN ARRAY chat_admins
      LOOP
        PERFORM realtime.send(
          json_build_object(
            'type', 'pendingMember',
            'chat_id', NEW.chat_id,
            'user_id', NEW.user_id
          )::jsonb,
          'event'::text,
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

COMMENT ON FUNCTION notify_members_new_message IS 'Notifies members via realtime and push notifications when a new message is sent';
COMMENT ON FUNCTION notify_admins_pending_member IS 'Notifies admins via realtime and push notifications when a member requests to join';
