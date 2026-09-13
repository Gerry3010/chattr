-- ============================================================================
-- 00033: System messages — kick vs. leave, admin promotions
-- ----------------------------------------------------------------------------
-- Context: system messages had silently died with the hybrid-KEM key format
-- switch (the insert-system-message Edge Function still expected RSA PEM keys
-- and skipped every recipient — fixed in the function, deploy required).
-- While restoring them:
--  * distinguish an admin KICK ('removed') from a voluntary LEAVE ('left') —
--    the deleting session's auth.uid() differs from the removed member on a
--    kick, and is NULL/equal on self-leave and definer cascades;
--  * announce admin PROMOTIONS in group chats (demotions deliberately get no
--    message, per product decision; 1:1 chats have no admin management).
--
-- notify_membership_change: same as 00003 (search_path pinned per 00022 —
-- re-declared inline because CREATE OR REPLACE drops ALTER-applied settings),
-- plus the removed/left distinction.
-- ============================================================================

CREATE OR REPLACE FUNCTION notify_membership_change()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql
AS $$
DECLARE
  changed_user_id UUID;
  action TEXT;
  member_record RECORD;
  username_text TEXT;
BEGIN
  -- Determine action and affected user
  IF TG_OP = 'INSERT' THEN
    changed_user_id := NEW.user_id;
    action := 'joined';
  ELSIF TG_OP = 'DELETE' THEN
    changed_user_id := OLD.user_id;
    -- An authenticated session deleting SOMEONE ELSE's membership is an admin
    -- kick (RLS only lets admins do that). Self-delete and definer cascades
    -- (account deletion, cleanup) read as a plain leave.
    IF auth.uid() IS NOT NULL AND auth.uid() != OLD.user_id THEN
      action := 'removed';
    ELSE
      action := 'left';
    END IF;
  ELSE
    -- For UPDATE, we don't track anymore
    RETURN NEW;
  END IF;

  -- Get username for system message
  SELECT username INTO username_text
  FROM profiles
  WHERE id = changed_user_id;

  username_text := COALESCE(username_text, 'A user');

  -- Insert encrypted system message for all members
  PERFORM insert_system_message(
    COALESCE(NEW.chat_id, OLD.chat_id),
    action,
    changed_user_id,
    username_text
  );

  -- Notify all members of this chat (except the changed user)
  FOR member_record IN
    SELECT user_id
    FROM chat_members
    WHERE chat_id = COALESCE(NEW.chat_id, OLD.chat_id)
      AND user_id != changed_user_id
  LOOP
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
$$;

-- Promotions: announce every uuid newly added to chats.admins (groups only).
CREATE OR REPLACE FUNCTION notify_admin_promotion()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql
AS $$
DECLARE
  promoted_id UUID;
  username_text TEXT;
BEGIN
  IF NOT NEW.is_group OR NEW.admins IS NOT DISTINCT FROM OLD.admins THEN
    RETURN NEW;
  END IF;

  FOR promoted_id IN
    SELECT a FROM unnest(NEW.admins) AS a
    EXCEPT
    SELECT a FROM unnest(OLD.admins) AS a
  LOOP
    SELECT username INTO username_text FROM profiles WHERE id = promoted_id;
    PERFORM insert_system_message(
      NEW.id,
      'promoted',
      promoted_id,
      COALESCE(username_text, 'A user')
    );
  END LOOP;

  -- Demotions intentionally announce nothing.
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS notify_admin_promotion_trigger ON chats;
CREATE TRIGGER notify_admin_promotion_trigger
  AFTER UPDATE ON chats
  FOR EACH ROW
  EXECUTE FUNCTION notify_admin_promotion();

COMMENT ON FUNCTION notify_membership_change IS
  'Notifies members about membership changes (joined/left/removed) and creates system messages';
COMMENT ON FUNCTION notify_admin_promotion IS
  'Creates a system message when a group member is promoted to admin (demotions are silent)';
