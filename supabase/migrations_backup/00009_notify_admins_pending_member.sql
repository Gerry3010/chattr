-- Migration: Notify admins when a new member requests to join a group chat
-- Sends a pendingMember event to all admins of the chat

-- 1. Create function to notify admins about pending member requests
CREATE OR REPLACE FUNCTION notify_admins_pending_member()
RETURNS TRIGGER
SECURITY DEFINER
AS $$
DECLARE
  admin_id TEXT;
  chat_admins TEXT[];
BEGIN
  -- Only notify if the member is not yet accepted (pending)
  IF NEW.accepted = FALSE THEN
    -- Get the list of admins for this chat
    SELECT admins INTO chat_admins
    FROM chats
    WHERE id = NEW.chat_id;

    -- Notify each admin
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
    END IF;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION notify_admins_pending_member IS 'Notifies all admins of a chat when a new member requests to join (accepted=false)';

-- 2. Create trigger for pending member notifications
DROP TRIGGER IF EXISTS notify_admins_pending_member_trigger ON chat_members;

CREATE TRIGGER notify_admins_pending_member_trigger
AFTER INSERT ON chat_members
FOR EACH ROW
EXECUTE FUNCTION notify_admins_pending_member();

COMMENT ON TRIGGER notify_admins_pending_member_trigger ON chat_members IS 'Fires when a new member is added to a chat with accepted=false, notifying all admins';
