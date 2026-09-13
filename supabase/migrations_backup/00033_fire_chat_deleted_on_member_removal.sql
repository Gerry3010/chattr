-- Fire chatDeleted event when a user is removed from chat_members
-- This notifies the removed user that they should delete the chat locally

CREATE OR REPLACE FUNCTION notify_chat_deleted_on_member_removal()
RETURNS TRIGGER
SECURITY DEFINER
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
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION notify_chat_deleted_on_member_removal IS 'Notifies a user via chatDeleted event when they are removed from a chat';

-- Create trigger that fires AFTER a member is deleted
DROP TRIGGER IF EXISTS notify_chat_deleted_trigger ON chat_members;

CREATE TRIGGER notify_chat_deleted_trigger
AFTER DELETE ON chat_members
FOR EACH ROW
EXECUTE FUNCTION notify_chat_deleted_on_member_removal();

COMMENT ON TRIGGER notify_chat_deleted_trigger ON chat_members IS 'Sends chatDeleted event when a user is removed from chat_members';
