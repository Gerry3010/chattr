-- SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
-- SPDX-License-Identifier: AGPL-3.0-or-later

-- ============================================================================
-- 00068: message_type 'summary' (push-free) + profiles.is_agent
-- ----------------------------------------------------------------------------
-- Two building blocks for the agent's chat summary (1.13):
--
-- 1) **'summary' as a third message_type.** The summary's request and answer
-- travel as ordinary end-to-end encrypted messages (the agent is not a server
-- the app could call — it is woken by a message). The server sees no plaintext
-- and cannot tell machinery from conversation — the SENDER has to say so. That
-- is what the type is for: the push gate in the trigger switches from
-- "everything but system" to **'user' only**, so one's own finished summary
-- does not ring on the phone as "new message". **Realtime fires unchanged for
-- ALL types** — the message has to arrive, and the sleeping agent has to be
-- woken.
--
-- Old clients (before 1.13) do not know the value and discard the row while
-- parsing — for machinery they could not display, that is the right behaviour.
--
-- 2) **profiles.is_agent.** Until now there was NO attribute distinguishing
-- agent accounts from human ones — the agent section in the info screen needs
-- one. Self-declared at registration through the MCP server, backfilled from
-- the MCP bind lineage (non-owner members of is_mcp chats — the same heuristic
-- revoke_mcp_token has used server-side since 00041). **A display attribute,
-- not a security boundary**: no permissions hang on it; an account falsely
-- claiming to be an agent merely sorts itself into the wrong list.
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
-- Push gate: from "everything but system" to "user only". A complete
-- restatement of the 00067 function; the only change is the gate
-- (`NEW.message_type = 'user'` instead of `!= 'system'`). The realtime
-- broadcast above stays unconditional.
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

-- Backfill: non-owner members of MCP chats are the agents — the same assumption
-- with which revoke_mcp_token (00041) removes agents server-side. It holds as
-- long as no second HUMAN sits in an MCP chat; checking that against the real
-- data is part of the staging acceptance test (look at a SELECT of the flagged
-- accounts BEFORE the prod deploy).
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
