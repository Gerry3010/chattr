-- ============================================================================
-- 00065: push without plaintext, stage 1 — preparation (server)
-- ============================================================================
-- Today the chat name and the sender's username travel in the clear to Google and
-- Apple: `title` = the chat name, `body` = "new message from <username>", plus
-- `data.sender_name`. The message's content is end-to-end encrypted — WHO writes to
-- WHOM stands in the push in the clear regardless.
--
-- This migration makes the server ready to LEAVE the text out, so the device builds
-- it itself from its local database. In itself it changes nothing about the display
-- yet: the edge function omits the text only for tokens that have set
-- `local_render = TRUE`, and only a client that can render locally does that. An old
-- client still gets everything as before and does not go silent — that is the
-- column's whole purpose.
--
-- Two parts:
--   1. device_tokens.local_render — the rollout gate, per device.
--   2. The three push triggers pass the sender's id instead of the plaintext name.
--      The device resolves the name locally; for iOS tokens `title`/`body` at the
--      top of the payload stay unchanged (stage 2).
--
-- The function bodies below are read out of the RUNNING database
-- (pg_get_functiondef), not assembled from the migration files: all three were
-- replaced across several migrations (00003/00011/00022/00029/00037/00063), and a
-- reconstruction from the files would silently have restored an older version.

ALTER TABLE device_tokens
  ADD COLUMN IF NOT EXISTS local_render BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN device_tokens.local_render IS
  'Gerät kann die Benachrichtigung selbst aus seiner lokalen DB rendern. '
  'TRUE → die Edge-Function schickt an dieses Token nur noch {type, chat_id, '
  'message_id, sender_id} und KEIN title/body. Default FALSE, damit ältere '
  'Installationen nicht stumm werden.';

-- ============================================================================
-- Push trigger: sender_name (plaintext) → sender_id
-- ============================================================================
-- The Dart client reads `data.sender_name` / `data.requester_name` nowhere
-- (verified), so these fields were pure leakage. `title`/`body` at the top of
-- the payload stay — iOS still displays from those until stage 2.

CREATE OR REPLACE FUNCTION public.notify_members_new_message()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  chat_name TEXT;
  sender_name TEXT;
  function_url TEXT;
  is_muted BOOLEAN;
BEGIN
  IF NEW.recipient_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT name INTO chat_name FROM chats WHERE id = NEW.chat_id;
  SELECT username INTO sender_name FROM profiles WHERE id = NEW.sender_id;
  chat_name := COALESCE(chat_name, 'Chat');
  sender_name := COALESCE(sender_name, 'Someone');

  -- Realtime always fires (the message must arrive), regardless of mute.
  -- reply_to_* ride along so recipients can render + persist the quote
  -- (jsonb_build_object turns NULLs into JSON nulls; the client treats
  -- missing/null identically).
  PERFORM public.chattr_send(
    jsonb_build_object(
      'type', 'newMessage',
      'chat_id', NEW.chat_id,
      'message_id', NEW.id,
      'sender_id', NEW.sender_id,
      'content', NEW.encrypted_content,
      'message_type', NEW.message_type,
      'reply_to_message_id', NEW.reply_to_message_id,
      'reply_to_sender_id', NEW.reply_to_sender_id,
      'reply_to_sender_name', NEW.reply_to_sender_name,
      'reply_to_preview', NEW.reply_to_preview,
      'timestamp', NOW()
    ),
    'event',
    'user:' || NEW.recipient_id::text,
    FALSE
  );

  -- Push only for non-system messages AND when the recipient hasn't muted it
  -- (a mute with muted_until in the past no longer counts).
  SELECT EXISTS (
    SELECT 1 FROM chat_mute_prefs
    WHERE user_id = NEW.recipient_id
      AND chat_id = NEW.chat_id
      AND (muted_until IS NULL OR muted_until > NOW())
  ) INTO is_muted;

  IF NEW.message_type != 'system' AND NOT is_muted THEN
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
          'type', 'new_message',
          'user_ids', ARRAY[NEW.recipient_id],
          'title', chat_name,
          'body', 'Neue Nachricht von ' || sender_name,
          'data', jsonb_build_object(
            'type', 'new_message',
            'chat_id', NEW.chat_id::text,
            'message_id', NEW.id::text,
            'sender_id', NEW.sender_id::text
          )
        )
      );
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Failed to send push notification: %', SQLERRM;
    END;
  END IF;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.notify_reaction_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
    PERFORM public.chattr_send(
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
              'sender_id', v_row.user_id::text
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
$function$;

CREATE OR REPLACE FUNCTION public.notify_admins_pending_member()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  admin_id TEXT;
  chat_admins TEXT[];
  chat_name TEXT;
  requester_name TEXT;
  admin_uuids UUID[];
  function_url TEXT;
BEGIN
  -- Get the list of admins for this chat
  SELECT admins INTO chat_admins
  FROM chats
  WHERE id = NEW.chat_id;

  -- Get chat name and requester username
  SELECT name INTO chat_name FROM chats WHERE id = NEW.chat_id;
  SELECT username INTO requester_name FROM profiles WHERE id = NEW.user_id;

  chat_name := COALESCE(chat_name, 'Chat');
  requester_name := COALESCE(requester_name, 'Someone');

  -- Send realtime notifications to each admin
  IF chat_admins IS NOT NULL THEN
    FOREACH admin_id IN ARRAY chat_admins
    LOOP
      PERFORM public.chattr_send(
        jsonb_build_object(
          'type', 'pendingMember',
          'chat_id', NEW.chat_id,
          'user_id', NEW.user_id,
          'timestamp', NOW()
        ),
        'event',
        'user:' || admin_id,
        FALSE
      );
    END LOOP;

    -- Convert TEXT[] to UUID[] for push notifications
    admin_uuids := (
      SELECT ARRAY_AGG(aid::UUID)
      FROM unnest(chat_admins) AS aid
    );

    -- Send push notifications
    IF admin_uuids IS NOT NULL AND array_length(admin_uuids, 1) > 0 THEN
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
            'type', 'member_request',
            'user_ids', admin_uuids,
            'title', 'New Join Request',
            'body', requester_name || ' wants to join ' || chat_name,
            'data', jsonb_build_object(
              'type', 'member_request',
              'chat_id', NEW.chat_id::text,
              'requester_id', NEW.user_id::text
            )
          )
        );
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'Failed to send push notification: %', SQLERRM;
      END;
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;
