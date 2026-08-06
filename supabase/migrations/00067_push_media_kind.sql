-- SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
-- SPDX-License-Identifier: AGPL-3.0-or-later

-- ============================================================================
-- 00067: "… hat ein Foto gesendet" im Push — abschaltbar pro Empfänger
-- ----------------------------------------------------------------------------
-- Seit 00065 trägt der Push nur noch IDs, die Benachrichtigung lautet also
-- „Neue Nachricht von X" — auch bei einem Foto. Diese Migration gibt die grobe
-- Medienkategorie mit, damit das Gerät „X hat ein Foto gesendet" bauen kann.
--
-- **Was das kostet, ehrlich benannt.** Unser Server weiß die Kategorie ohnehin:
-- seit 00066 trägt jeder Blob sein `x-media-kind`, und sein Pfad ist
-- `<chat_id>/<message_id>/…`. Neu ist NICHT, dass wir es wissen — neu ist, dass
-- es an Google/Apple mitgeht. Deren Push-Dienst erfährt heute schon Zeitpunkt,
-- Gerät, chat_id, sender_id und message_id; hinzu käme eine Kategorie aus vier
-- Werten. Kein Inhalt, kein Dateiname, keine Größe.
--
-- Deshalb entscheidet der EMPFÄNGER: `profiles.push_media_kind`, Voreinstellung
-- TRUE. Es ist seine Benachrichtigung auf seinem Gerät, also seine Abwägung —
-- anders als bei Lesebestätigungen braucht es hier keine Gegenseitigkeit.
-- Steht es auf FALSE, entsteht das Feld gar nicht erst, statt später
-- weggefiltert zu werden.
--
-- Die Kategorie wird aus `storage.objects` GELESEN, nicht neu gespeichert. Das
-- ist der Punkt: es entsteht kein zusätzliches Metadatum in der Datenbank, nur
-- ein Nachschlagen dessen, was ohnehin dasteht. Ein Feld auf `messages` wäre
-- einfacher gewesen und hätte die Metadatenspur vergrößert.
-- ============================================================================

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS push_media_kind BOOLEAN NOT NULL DEFAULT TRUE;

COMMENT ON COLUMN public.profiles.push_media_kind IS
  'Darf die grobe Medienkategorie (image/video/audio/other) im Push an den '
  'Push-Dienst mitgehen, damit die Benachrichtigung „hat ein Foto gesendet" '
  'lauten kann? Entscheidung des Empfängers, Voreinstellung TRUE. FALSE = der '
  'Push bleibt bei „Neue Nachricht von X".';

-- ----------------------------------------------------------------------------
-- Kategorie einer Nachricht, aus dem bereits getaggten Blob.
-- ----------------------------------------------------------------------------
-- `starts_with()` und NICHT die scheinbar index-freundliche Bereichsabfrage
-- `name >= präfix || '/' AND name < präfix || '0'`. Die war der erste Versuch
-- und lieferte gegen echte Daten NULL: Zeichenketten-Vergleiche folgen der
-- Kollation der Datenbank, nicht der ASCII-Reihenfolge, und dort sortiert '/'
-- gegen '0' nicht so, wie die Byte-Werte vermuten lassen. `starts_with` ist
-- exakt und kollationsunabhängig. Der Bucket hat einige hundert Objekte —
-- die verlorene Index-Nutzung ist hier kein Thema, eine falsche Antwort schon.
--
-- NULL heißt „keine Medien" ODER „von einem Client ohne 00066-Tag gesendet".
-- Beide führen zur bisherigen Formulierung — die Kategorie ist ein Zusatz, ihr
-- Fehlen darf nie eine Benachrichtigung verschlucken.
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
-- Trigger: Kategorie mitgeben, wenn dieser Empfänger es erlaubt.
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
    -- Nur nachschlagen, wenn dieser Empfänger es überhaupt will — sonst wird
    -- für nichts in storage.objects gesucht.
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
            -- strip_nulls: ohne Medien / ohne Einwilligung ist der Schlüssel
            -- gar nicht da, nicht bloß leer.
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
