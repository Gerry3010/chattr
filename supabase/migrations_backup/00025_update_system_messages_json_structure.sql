-- Update insert_system_message to accept subject_id and subject_name for translation support
-- System messages will now store encrypted JSON: {action, subject_id, subject_name}

-- Drop and recreate function with new signature
DROP FUNCTION IF EXISTS insert_system_message(
  UUID, TEXT, TEXT
);

CREATE OR REPLACE FUNCTION insert_system_message(
  p_chat_id      UUID,
  p_action       TEXT,
  p_subject_id   UUID,
  p_subject_name TEXT
)
  RETURNS VOID
  SECURITY DEFINER
AS
$$
DECLARE
  function_url TEXT;
  response     TEXT;
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
    FROM
      extensions.http(
          (
           'POST',
           function_url,
           ARRAY [extensions.http_header('Authorization',
                                         'Bearer ' || private.get_secret('service_role_key'))],
           'application/json',
           jsonb_build_object(
               'chat_id', p_chat_id::text,
               'action', p_action,
               'subject_id', p_subject_id::text,
               'subject_name', p_subject_name
           )::text
            )
      );
  EXCEPTION
    WHEN OTHERS THEN
      -- Log error but don't fail the trigger
      RAISE WARNING 'Failed to call insert-system-message Edge Function: %', SQLERRM;
  END;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION insert_system_message IS 'Calls Edge Function to encrypt and insert system message with JSON structure {action, subject_id, subject_name}';

-- Update notify_membership_change to use the new function signature
CREATE OR REPLACE FUNCTION notify_membership_change(
)
  RETURNS TRIGGER
  SECURITY DEFINER
AS
$$
DECLARE
  changed_user_id uuid;
  action          text;
  member_record   record;
  username_text   text;
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

  -- Get the username for the system message
  SELECT username
  INTO username_text
  FROM profiles
  WHERE id = changed_user_id;

  username_text := COALESCE(username_text, 'Unknown User');

  -- Insert encrypted system message for all members with JSON structure
  -- noinspection SqlRedundantCodeInCoalesce
  PERFORM insert_system_message(
      COALESCE(NEW.chat_id, OLD.chat_id),
      action,
      changed_user_id,
      username_text
          );

  -- Notify all ACCEPTED members of this chat (except the changed user)
  FOR member_record IN
    SELECT user_id
    FROM chat_members
    WHERE
      chat_id = COALESCE(NEW.chat_id, OLD.chat_id)
      AND accepted = true
      AND user_id != changed_user_id
    LOOP
      -- noinspection SqlRedundantCodeInCoalesce
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

COMMENT ON FUNCTION notify_membership_change IS 'Notifies members about membership changes (joined/left/approved) and creates system messages with JSON structure';
