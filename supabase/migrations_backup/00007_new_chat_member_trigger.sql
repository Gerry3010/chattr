-- Migration: Add trigger to broadcast newChat events when members are added to chats
-- This replaces the old member_keys update trigger with a simpler approach

-- 1. Create function to broadcast new chat membership
CREATE OR REPLACE FUNCTION broadcast_new_chat_member()
RETURNS TRIGGER
SECURITY DEFINER
AS $$
BEGIN
  -- Notify the new member about the chat they were added to
  PERFORM realtime.send(
    json_build_object(
      'type', 'newChat',
      'chat_id', NEW.chat_id
    )::jsonb,
    'event'::text,
    'user:' || NEW.user_id::text,
    FALSE
  );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION broadcast_new_chat_member IS 'Broadcasts a newChat event to the user when they are added to a chat';

-- 2. Create trigger for new chat members
DROP TRIGGER IF EXISTS new_chat_member_trigger ON chat_members;

CREATE TRIGGER new_chat_member_trigger
AFTER INSERT ON chat_members
FOR EACH ROW
EXECUTE FUNCTION broadcast_new_chat_member();

COMMENT ON TRIGGER new_chat_member_trigger ON chat_members IS 'Fires when a new member is added to a chat, notifying the user via pg_notify';
