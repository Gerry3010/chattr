-- Optimize message notifications to only notify the recipient_id
-- Since each message is created for a specific recipient, we should only
-- notify that one user instead of querying all chat members

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
    json_build_object(
      'type', 'newMessage',
      'chat_id', NEW.chat_id,
      'message_id', NEW.id,
      'sender_id', NEW.sender_id,
      'content', NEW.encrypted_content,
      'timestamp', NEW.created_at
    )::jsonb,
    'event'::text,
    'user:' || NEW.recipient_id::text,
    FALSE
  );

  -- Send push notification to the specific recipient
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
    -- Log error but don't fail the trigger
    RAISE WARNING 'Failed to send push notification: %', SQLERRM;
  END;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION notify_members_new_message IS 'Notifies the specific recipient via realtime and push notification when a new message is sent';