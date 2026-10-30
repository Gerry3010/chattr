-- SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
-- SPDX-License-Identifier: AGPL-3.0-or-later

-- ============================================================================
-- 00067: "… sent a photo" in the push — switchable per recipient
-- ----------------------------------------------------------------------------
-- Since 00065 the push carries only ids, so the notification reads "new message
-- from X" — for a photo too. This migration passes the coarse media category
-- along so the device can build "X sent a photo".
--
-- **What that costs, named honestly.** Our server knows the category anyway:
-- since 00066 every blob carries its `x-media-kind`, and its path is
-- `<chat_id>/<message_id>/…`. What is new is NOT that we know it — what is new
-- is that it goes to Google/Apple. Their push service already learns the time,
-- the device, chat_id, sender_id and message_id today; a category out of four
-- values would be added. No content, no file name, no size.
--
-- That is why the RECIPIENT decides: `profiles.push_media_kind`, default TRUE.
-- It is their notification on their device, so it is their trade-off — unlike
-- read receipts, no reciprocity is needed here. If it is FALSE, the field does
-- not come into being in the first place, rather than being filtered out later.
--
-- The category is READ from `storage.objects`, not stored anew. That is the
-- point: no additional metadata comes into being in the database, only a lookup
-- of what is there anyway. A field on `messages` would have been simpler and
-- would have enlarged the metadata trail.
-- ============================================================================

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS push_media_kind BOOLEAN NOT NULL DEFAULT TRUE;

COMMENT ON COLUMN public.profiles.push_media_kind IS
  'Darf die grobe Medienkategorie (image/video/audio/other) im Push an den '
  'Push-Dienst mitgehen, damit die Benachrichtigung „hat ein Foto gesendet" '
  'lauten kann? Entscheidung des Empfängers, Voreinstellung TRUE. FALSE = der '
  'Push bleibt bei „Neue Nachricht von X".';

-- ----------------------------------------------------------------------------
-- A message's category, from the already tagged blob.
-- ----------------------------------------------------------------------------
-- `starts_with()` and NOT the seemingly index-friendly range query `name >=
-- prefix || '/' AND name < prefix || '0'`. That was the first attempt and
-- returned NULL against real data: string comparisons follow the database's
-- collation, not ASCII order, and there '/' does not sort against '0' the way
-- the byte values suggest. `starts_with` is exact and collation-independent.
-- The bucket has a few hundred objects — the lost index use is not an issue
-- here, a wrong answer is.
--
-- NULL means "no media" OR "sent by a client without the 00066 tag". Both lead
-- to the previous wording — the category is an addition, its absence must never
-- swallow a notification.
CREATE OR REPLACE FUNCTION public.message_media_kind(p_chat_id UUID, p_message_id UUID)
RETURNS TEXT
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE sql
STABLE
AS $$
  SELECT NULLIF(o.user_metadata->>'x-media-kind', '')
  FROM storage.objects o
  WHERE o.bucket_id = 'media'
    AND starts_with(o.name, p_chat_id::text || '/' || p_message_id::text || '/')
    AND NULLIF(o.user_metadata->>'x-media-kind', '') IS NOT NULL
  LIMIT 1;
$$;

REVOKE EXECUTE ON FUNCTION public.message_media_kind(uuid, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.message_media_kind(uuid, uuid) FROM anon, authenticated;

-- ----------------------------------------------------------------------------
-- Trigger: pass the category along when this recipient allows it.
-- ----------------------------------------------------------------------------
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
  wants_kind BOOLEAN;
  media_kind TEXT;
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
    -- Only look it up when this recipient wants it at all — otherwise
    -- storage.objects is searched for nothing.
    SELECT COALESCE(push_media_kind, TRUE) INTO wants_kind
    FROM profiles WHERE id = NEW.recipient_id;
    IF COALESCE(wants_kind, TRUE) THEN
      media_kind := public.message_media_kind(NEW.chat_id, NEW.id);
    END IF;

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
          'data', jsonb_strip_nulls(jsonb_build_object(
            'type', 'new_message',
            'chat_id', NEW.chat_id::text,
            'message_id', NEW.id::text,
            'sender_id', NEW.sender_id::text,
            -- strip_nulls: without media / without consent the key is not there
            -- at all, not merely empty.
            'media_kind', media_kind
          ))
        )
      );
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Failed to send push notification: %', SQLERRM;
    END;
  END IF;

  RETURN NEW;
END;
$function$;
