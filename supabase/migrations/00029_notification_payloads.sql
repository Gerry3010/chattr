-- ============================================================================
-- 00029: Notification payload fixes
-- ----------------------------------------------------------------------------
-- 1) Push taps never navigated: NotificationNavigationHandler switches on
--    data['type'], but 'type' was only a TOP-LEVEL field of the edge-function
--    request body (used for routing there) and never inside `data` — the only
--    part forwarded into the FCM message. Add 'type' to `data` for both
--    new_message and member_request pushes.
-- 2) Reply metadata was absent from the realtime newMessage broadcast, so
--    recipients received replies as plain messages (no quote) and persisted
--    the stripped copy locally — while the server ciphertext gets cleared on
--    receipt, making the quote unrecoverable. Broadcast the reply_to_* columns
--    (reply_to_preview is the per-recipient RSA ciphertext of the quoted
--    text; the client decrypts it like `content`).
--
-- notify_members_new_message: same function as 00028, plus the two additions.
-- notify_admins_pending_member: same function as 00003 (search_path pinned by
-- 00022 via ALTER — re-declared inline here because CREATE OR REPLACE drops
-- ALTER-applied settings), plus 'type' in data.
-- ============================================================================

CREATE OR REPLACE FUNCTION notify_members_new_message()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql
AS $$
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
  PERFORM realtime.send(
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
            'sender_name', sender_name
          )
        )
      );
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Failed to send push notification: %', SQLERRM;
    END;
  END IF;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION notify_admins_pending_member()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql
AS $$
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
      PERFORM realtime.send(
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
              'requester_id', NEW.user_id::text,
              'requester_name', requester_name
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
$$;

COMMENT ON FUNCTION notify_members_new_message IS
  'Broadcasts newMessage (incl. reply_to_* metadata) per recipient and sends the push (data carries type for tap navigation).';
COMMENT ON FUNCTION notify_admins_pending_member IS
  'Notifies admins when a user requests to join via pending_chat_members (push data carries type for tap navigation).';
