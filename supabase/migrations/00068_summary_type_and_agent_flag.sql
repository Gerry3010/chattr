-- SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
-- SPDX-License-Identifier: AGPL-3.0-or-later

-- ============================================================================
-- 00068: message_type 'summary' (pushfrei) + profiles.is_agent
-- ----------------------------------------------------------------------------
-- Zwei Bausteine für die Chat-Zusammenfassung durch den Agenten (1.13):
--
-- 1) **'summary' als dritter message_type.** Anfrage und Antwort der
--    Zusammenfassung reisen als gewöhnliche E2E-verschlüsselte Nachrichten
--    (der Agent ist kein Server, den die App aufrufen könnte — er wird von
--    einer Nachricht geweckt). Der Server sieht keinen Klartext und kann
--    Maschinerie nicht von Konversation unterscheiden — der SENDER muss es
--    sagen. Genau dafür ist der Typ da: Das Push-Gate im Trigger stellt von
--    „alles außer system" auf **nur 'user'** um, damit die fertige eigene
--    Zusammenfassung nicht als „Neue Nachricht" aufs Handy klingelt.
--    **Realtime feuert unverändert für ALLE Typen** — die Nachricht muss
--    ankommen, und der schlafende Agent muss geweckt werden.
--
--    Alt-Clients (vor 1.13) kennen den Wert nicht und verwerfen die Zeile
--    beim Parsen — für Maschinerie, die sie nicht darstellen könnten, ist
--    das das richtige Verhalten.
--
-- 2) **profiles.is_agent.** Es gab bisher KEIN Merkmal, das Agenten-Konten
--    von menschlichen unterscheidet — die Agenten-Sektion im Info-Screen
--    braucht eines. Selbstdeklariert bei der Registrierung über den
--    MCP-Server, Backfill über die MCP-Bind-Abstammung (Nicht-Owner-
--    Mitglieder von is_mcp-Chats — dieselbe Heuristik, die revoke_mcp_token
--    seit 00041 serverseitig verwendet). **Anzeige-Merkmal, keine
--    Sicherheitsgrenze**: Rechte hängen nirgends daran, ein Konto das sich
--    fälschlich als Agent ausgibt, sortiert sich nur in die falsche Liste.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1) message_type-Check um 'summary' erweitern.
-- ----------------------------------------------------------------------------
ALTER TABLE public.messages
  DROP CONSTRAINT IF EXISTS messages_message_type_check;
ALTER TABLE public.messages
  ADD CONSTRAINT messages_message_type_check
  CHECK (message_type = ANY (ARRAY['user'::TEXT, 'system'::TEXT, 'summary'::TEXT]));

COMMENT ON COLUMN public.messages.message_type IS
  'user = Konversation; system = Systemnachricht; summary = Maschinerie der '
  'Chat-Zusammenfassung (Anfrage/Antwort, lib/features/summary/). summary '
  'verhält sich wie user (verschlüsselt, Realtime, Empfangs-Löschung), löst '
  'aber KEINE Push aus und wird von keinem Client als Blase gezeigt.';

-- ----------------------------------------------------------------------------
-- Push-Gate: von "alles außer system" auf "nur user".
-- Vollständige Neufassung der 00067-Funktion; einzige Änderung ist das Gate
-- (`NEW.message_type = 'user'` statt `!= 'system'`). Realtime-Broadcast oben
-- bleibt bedingungslos.
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

  -- Realtime always fires (the message must arrive), regardless of mute —
  -- and regardless of message_type: the summary reply reaches the sheet and
  -- the sleeping agent gets woken by the request precisely because of this.
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

  SELECT EXISTS (
    SELECT 1 FROM chat_mute_prefs
    WHERE user_id = NEW.recipient_id
      AND chat_id = NEW.chat_id
      AND (muted_until IS NULL OR muted_until > NOW())
  ) INTO is_muted;

  -- Push ONLY for real conversation ('user'). 'system' was already excluded;
  -- 'summary' is machinery the recipient asked for himself — a push for it
  -- would announce the feature's own plumbing (00068).
  IF NEW.message_type = 'user' AND NOT is_muted THEN
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

-- ----------------------------------------------------------------------------
-- 2) profiles.is_agent + Backfill.
-- ----------------------------------------------------------------------------
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS is_agent BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN public.profiles.is_agent IS
  'Selbstdeklaration: dieses Konto ist ein MCP-Agent (gesetzt bei der '
  'Registrierung über mcp_server, Backfill 00068 über die MCP-Bind-'
  'Abstammung). Reines Anzeige-Merkmal für die Agenten-Sektion im '
  'Info-Screen — KEINE Sicherheitsgrenze, keine Rechte hängen daran.';

-- Backfill: Nicht-Owner-Mitglieder von MCP-Chats sind die Agenten — dieselbe
-- Annahme, mit der revoke_mcp_token (00041) serverseitig Agenten entfernt.
-- Sie stimmt, solange kein zweiter MENSCH in einem MCP-Chat sitzt; das gegen
-- die echten Daten zu prüfen ist Teil des Staging-Abnahmetests (SELECT der
-- geflaggten Konten VOR dem Prod-Deploy ansehen).
UPDATE public.profiles p
SET is_agent = TRUE
WHERE EXISTS (
  SELECT 1
  FROM public.chat_members cm
  JOIN public.chats c ON c.id = cm.chat_id
  WHERE cm.user_id = p.id
    AND c.is_mcp
    AND c.mcp_owner_id IS DISTINCT FROM p.id
);
