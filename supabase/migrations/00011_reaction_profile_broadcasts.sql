-- 00011_reaction_profile_broadcasts.sql
--
-- Stage 3 (event-system refactor): move reaction and profile change notifications
-- onto the single user broadcast channel `user:<userId>`, the same channel that
-- already carries newMessage/membershipChanged/etc. This lets the client drop the
-- separate per-message/per-chat reaction channels and the profiles table-changes
-- channel, consolidating all realtime onto one channel + one typed event stream.
--
-- Events emitted here (parsed by the client EventBus):
--   reactionChanged  {chat_id, message_id, user_id, reaction, action: added|removed}
--   profileChanged   {user_id, username, action: updated|deleted}

-- ── Reactions ──────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION notify_reaction_change()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = ''
LANGUAGE plpgsql
AS $$
DECLARE
  v_row          RECORD;
  v_action       TEXT;
  v_chat_id      UUID;
  member_record  RECORD;
BEGIN
  IF TG_OP = 'INSERT' THEN
    v_row := NEW;
    v_action := 'added';
  ELSE
    v_row := OLD;          -- DELETE (message_reactions has REPLICA IDENTITY FULL)
    v_action := 'removed';
  END IF;

  -- Resolve the chat the reacted-to message belongs to. messages has a composite
  -- PK (id, recipient_id), so the same logical id spans rows with one chat_id.
  SELECT chat_id INTO v_chat_id
  FROM public.messages
  WHERE id = v_row.message_id
  LIMIT 1;

  IF v_chat_id IS NULL THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

  -- Broadcast to every member of that chat.
  FOR member_record IN
    SELECT user_id FROM public.chat_members WHERE chat_id = v_chat_id
  LOOP
    PERFORM realtime.send(
      jsonb_build_object(
        'type', 'reactionChanged',
        'chat_id', v_chat_id,
        'message_id', v_row.message_id,
        'user_id', v_row.user_id,
        'reaction', v_row.reaction,
        'action', v_action,
        'timestamp', NOW()
      ),
      'event',
      'user:' || member_record.user_id::text,
      FALSE
    );
  END LOOP;

  RETURN COALESCE(NEW, OLD);
END;
$$;

COMMENT ON FUNCTION notify_reaction_change IS 'Broadcasts reactionChanged to all chat members on the user:<id> channel';

DROP TRIGGER IF EXISTS notify_reaction_change_trigger ON message_reactions;
CREATE TRIGGER notify_reaction_change_trigger
  AFTER INSERT OR DELETE ON message_reactions
  FOR EACH ROW EXECUTE FUNCTION notify_reaction_change();

-- ── Profiles ───────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION notify_profile_change()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = ''
LANGUAGE plpgsql
AS $$
DECLARE
  v_row          RECORD;
  v_action       TEXT;
  member_record  RECORD;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    v_row := NEW;
    v_action := 'updated';
  ELSE
    v_row := OLD;          -- DELETE
    v_action := 'deleted';
  END IF;

  -- Notify the distinct co-members of every chat the changed user belongs to
  -- (they display this user's name/avatar). Excludes the changed user.
  FOR member_record IN
    SELECT DISTINCT cm.user_id
    FROM public.chat_members cm
    WHERE cm.chat_id IN (
      SELECT chat_id FROM public.chat_members WHERE user_id = v_row.id
    )
    AND cm.user_id <> v_row.id
  LOOP
    PERFORM realtime.send(
      jsonb_build_object(
        'type', 'profileChanged',
        'user_id', v_row.id,
        'username', CASE WHEN TG_OP = 'UPDATE' THEN v_row.username ELSE NULL END,
        'action', v_action,
        'timestamp', NOW()
      ),
      'event',
      'user:' || member_record.user_id::text,
      FALSE
    );
  END LOOP;

  RETURN COALESCE(NEW, OLD);
END;
$$;

COMMENT ON FUNCTION notify_profile_change IS 'Broadcasts profileChanged to chat co-members on the user:<id> channel';

-- Need full OLD row on DELETE.
ALTER TABLE profiles REPLICA IDENTITY FULL;

DROP TRIGGER IF EXISTS notify_profile_change_trigger ON profiles;
CREATE TRIGGER notify_profile_change_trigger
  AFTER UPDATE OR DELETE ON profiles
  FOR EACH ROW EXECUTE FUNCTION notify_profile_change();
