-- ============================================================================
-- 00024: Per-user chat mute (suppresses push notifications)
-- ----------------------------------------------------------------------------
-- A muted chat must not fire an OS push. Since the edge function sends FCM
-- "notification" messages (shown by the OS even when the app is killed), a
-- purely client-side mute cannot suppress background push — the filtering has
-- to happen server-side, in notify_members_new_message before net.http_post.
--
-- The mute preference (user_id, chat_id) is non-secret metadata, so storing it
-- server-side is E2E-safe. Realtime delivery is unaffected: a muted chat still
-- receives the message (and updates in-app), it just gets no push banner.
-- (Assumes 00021-00023 are applied.)
-- ============================================================================

CREATE TABLE IF NOT EXISTS chat_mute_prefs (
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  chat_id UUID NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  muted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (user_id, chat_id)
);

COMMENT ON TABLE chat_mute_prefs IS 'Per-user muted chats; presence = muted (suppresses push, not realtime)';

ALTER TABLE chat_mute_prefs ENABLE ROW LEVEL SECURITY;

-- A user sees and manages only their own mute rows.
CREATE POLICY "Users manage their own mutes"
ON chat_mute_prefs FOR ALL
USING (user_id = auth.uid())
WITH CHECK (user_id = auth.uid());

-- Rebuild the message-notify trigger with a mute check before the push, and
-- pin search_path (00022 convention; the original had none).
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
  PERFORM realtime.send(
    jsonb_build_object(
      'type', 'newMessage',
      'chat_id', NEW.chat_id,
      'message_id', NEW.id,
      'sender_id', NEW.sender_id,
      'content', NEW.encrypted_content,
      'message_type', NEW.message_type,
      'timestamp', NOW()
    ),
    'event',
    'user:' || NEW.recipient_id::text,
    FALSE
  );

  -- Push only for non-system messages AND when the recipient hasn't muted it.
  SELECT EXISTS (
    SELECT 1 FROM chat_mute_prefs
    WHERE user_id = NEW.recipient_id AND chat_id = NEW.chat_id
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
