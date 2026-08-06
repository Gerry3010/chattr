-- Fix event payload structure to match EventBusService expectations
-- The realtime.send() function should send the event payload directly,
-- not wrapped in a nested structure

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
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION notify_membership_change()
RETURNS TRIGGER
SECURITY DEFINER
AS $$
DECLARE
    changed_user_id uuid;
    action text;
    member_record record;
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
$$ LANGUAGE plpgsql;