-- Migration: Notify all chat members when a new message is sent
-- Sends a newMessage event to all members of the chat (except the sender)

-- 1. Create function to notify members about new messages
CREATE OR REPLACE FUNCTION notify_members_new_message()
RETURNS TRIGGER
SECURITY DEFINER
AS $$
DECLARE
  member_id TEXT;
  chat_members UUID[];
BEGIN
  -- Get all members of this chat who have accepted the invitation
  SELECT ARRAY_AGG(user_id) INTO chat_members
  FROM chat_members
  WHERE chat_id = NEW.chat_id
    AND user_id <> NEW.sender_id
    AND accepted = true;

  -- Notify each member (except the sender)
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

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION notify_members_new_message IS 'Notifies all accepted members of a chat when a new message is sent (except the sender)';

-- 2. Create trigger for new message notifications
DROP TRIGGER IF EXISTS notify_members_new_message_trigger ON messages;

CREATE TRIGGER notify_members_new_message_trigger
AFTER INSERT ON messages
FOR EACH ROW
EXECUTE FUNCTION notify_members_new_message();

COMMENT ON TRIGGER notify_members_new_message_trigger ON messages IS 'Fires when a new message is inserted, notifying all chat members';
