-- Migration: Notify member status changes and membership updates
-- 
-- This migration adds triggers to notify:
-- 1. Requesting users when their membership status changes (accepted/rejected)
-- 2. Accepted members when the member list changes

-- Function: Notify requesting user when their status changes
CREATE OR REPLACE FUNCTION notify_member_status_change()
RETURNS TRIGGER AS $$
DECLARE
    old_accepted BOOLEAN;
    new_accepted BOOLEAN;
BEGIN
    -- Get old and new accepted values
    old_accepted := OLD.accepted;
    new_accepted := NEW.accepted;
    
    -- Only notify if accepted status actually changed
    IF old_accepted IS DISTINCT FROM new_accepted THEN
        PERFORM realtime.send(
            jsonb_build_object(
                'type', 'memberStatusChanged',
                'chatId', NEW.chat_id,
                'userId', NEW.user_id,
                'accepted', NEW.accepted,
                'timestamp', NOW()
            )::jsonb,
            'event'::text,
            'user:' || NEW.user_id,
            FALSE
        );
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Trigger: On chat_members update, notify the user if their status changed
DROP TRIGGER IF EXISTS on_member_status_change ON chat_members;
CREATE TRIGGER on_member_status_change
    AFTER UPDATE ON chat_members
    FOR EACH ROW
    WHEN (OLD.accepted IS DISTINCT FROM NEW.accepted)
    EXECUTE FUNCTION notify_member_status_change();


-- Function: Notify accepted members when membership changes
CREATE OR REPLACE FUNCTION notify_membership_change()
RETURNS TRIGGER AS $$
DECLARE
    member_record RECORD;
    action TEXT;
    changed_user_id UUID;
BEGIN
    -- Determine action and user ID based on operation
    IF TG_OP = 'INSERT' THEN
        action := 'added';
        changed_user_id := NEW.user_id;
    ELSIF TG_OP = 'UPDATE' THEN
        action := 'updated';
        changed_user_id := NEW.user_id;
    ELSIF TG_OP = 'DELETE' THEN
        action := 'removed';
        changed_user_id := OLD.user_id;
    END IF;
    
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
                'chatId', COALESCE(NEW.chat_id, OLD.chat_id),
                'userId', changed_user_id,
                'action', action,
                'timestamp', NOW()
            )::jsonb,
            'event'::text,
            'user:' || member_record.user_id,
            FALSE
        );
    END LOOP;
    
    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Trigger: Notify on any membership change (insert/update/delete)
DROP TRIGGER IF EXISTS on_membership_change ON chat_members;
CREATE TRIGGER on_membership_change
    AFTER INSERT OR UPDATE OR DELETE ON chat_members
    FOR EACH ROW
    EXECUTE FUNCTION notify_membership_change();

-- Add comment for documentation
COMMENT ON FUNCTION notify_member_status_change() IS 
'Notifies a user on their personal channel when their membership status (accepted) changes';

COMMENT ON FUNCTION notify_membership_change() IS 
'Notifies all accepted members when the membership list of a chat changes';
