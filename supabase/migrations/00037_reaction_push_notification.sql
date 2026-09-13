-- ============================================================================
-- 00037: Push notification for new reactions
-- ----------------------------------------------------------------------------
-- The reacted-to message's author gets a push — title: chat name, body:
-- "<Reactor> hat mit <emoji> reagiert" (German-hardcoded like the message
-- push in 00024). Rules:
--   * only on INSERT (removals are silent),
--   * never for self-reactions,
--   * respects the author's chat mute (chat_mute_prefs),
--   * body carries no message content — the reaction emoji itself is
--     server-side plaintext anyway (message_reactions.reaction).
-- Extends notify_reaction_change() from 00011 (broadcast loop unchanged);
-- search_path stays '' as in the original, so all objects are qualified.
-- ============================================================================

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
  v_author_id    UUID;
  member_record  RECORD;
  v_chat_name    TEXT;
  v_reactor_name TEXT;
  v_is_muted     BOOLEAN;
  function_url   TEXT;
BEGIN
  IF TG_OP = 'INSERT' THEN
    v_row := NEW;
    v_action := 'added';
  ELSE
    v_row := OLD;          -- DELETE (message_reactions has REPLICA IDENTITY FULL)
    v_action := 'removed';
  END IF;

  -- Resolve the chat + author of the reacted-to message. messages has a
  -- composite PK (id, recipient_id); the same logical id spans rows with one
  -- chat_id/sender_id.
  SELECT chat_id, sender_id INTO v_chat_id, v_author_id
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

  -- Push to the message author on new reactions (not their own, not muted).
  IF v_action = 'added'
     AND v_author_id IS NOT NULL
     AND v_author_id != v_row.user_id THEN

    SELECT EXISTS (
      SELECT 1 FROM public.chat_mute_prefs
      WHERE user_id = v_author_id AND chat_id = v_chat_id
    ) INTO v_is_muted;

    IF NOT v_is_muted THEN
      SELECT name INTO v_chat_name FROM public.chats WHERE id = v_chat_id;
      SELECT username INTO v_reactor_name FROM public.profiles WHERE id = v_row.user_id;
      v_chat_name := COALESCE(v_chat_name, 'Chat');
      v_reactor_name := COALESCE(v_reactor_name, 'Jemand');

      function_url := COALESCE(
        current_setting('app.settings.edge_function_url', true),
        'http://kong:8000/functions/v1/send-push-notification'
      );

      BEGIN
        PERFORM net.http_post(
          url := function_url,
          headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'Authorization', 'Bearer ' || private.get_secret('service_role_key')
          ),
          body := jsonb_build_object(
            'type', 'reaction',
            'user_ids', ARRAY[v_author_id],
            'title', v_chat_name,
            'body', v_reactor_name || ' hat mit ' || v_row.reaction || ' reagiert',
            'data', jsonb_build_object(
              'type', 'reaction',
              'chat_id', v_chat_id::text,
              'message_id', v_row.message_id::text,
              'sender_name', v_reactor_name
            )
          )
        );
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'notify_reaction_change: push call failed: %', SQLERRM;
      END;
    END IF;
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

COMMENT ON FUNCTION notify_reaction_change IS
  'Broadcasts reactionChanged to all chat members and pushes new reactions to the message author (mute-aware, self-reactions silent)';
