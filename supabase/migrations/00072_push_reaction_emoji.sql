-- SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
-- SPDX-License-Identifier: AGPL-3.0-or-later

-- ============================================================================
-- 00072: "… reacted with 👍" in the push — switchable on per recipient
-- ----------------------------------------------------------------------------
-- Before "push without plaintext" (00065), the notification said WHAT somebody
-- reacted with. Since then the push carries only ids, and the allowlist in the
-- edge function (LOCAL_RENDER_DATA_KEYS) cuts everything else off — the emoji
-- travelled in the plaintext `body` and thereby fell away. What remained was "X
-- reacted to your message". That is precisely what was missing.
--
-- **What it costs, named honestly.** The emoji is message content. Google and
-- Apple learn the time, the device, chat_id, message_id and sender_id today; a
-- single character somebody answered a message with would be added. Little —
-- but it is the first exception to the rule 00065 has only just enforced, and
-- that is why it gets a switch rather than a silent extension.
--
-- Default **FALSE**, unlike `push_media_kind` (00067). There a category out of
-- four values travels along; here content travels along. Whoever wants to see
-- it in the push says so. If the switch is off, the field does not come into
-- being in the first place — it is not filtered out later but never built.
--
-- The rest of the function is word for word the state from 00065; new are only
-- `wants_emoji` and the conditional key in the `data` object.
-- ============================================================================

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS push_reaction_emoji BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN public.profiles.push_reaction_emoji IS
  'Darf das Reaktions-Emoji im Push an den Push-Dienst (FCM/APNs) mitgehen, '
  'damit die Benachrichtigung „X hat mit 👍 reagiert" lauten kann? Entscheidung '
  'des Empfängers, Voreinstellung FALSE — es ist Nachrichten-Inhalt. FALSE = '
  'der Push bleibt bei „X hat auf deine Nachricht reagiert".';

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
  v_wants_emoji  BOOLEAN;
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

      -- Only the RECIPIENT decides whether the emoji may reach their device
      -- through the push service. COALESCE to FALSE: if the column is missing
      -- on an old instance, or the profile is, the reticent answer applies.
      SELECT COALESCE(push_reaction_emoji, FALSE) INTO v_wants_emoji
      FROM public.profiles WHERE id = v_author_id;

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
            'data', jsonb_strip_nulls(jsonb_build_object(
              'type', 'reaction',
              'chat_id', v_chat_id::text,
              'message_id', v_row.message_id::text,
              'sender_id', v_row.user_id::text,
              -- strip_nulls: without consent the key is not there at all, not
              -- merely empty. The device then falls back on the sentence
              -- without the emoji, as before.
              'reaction', CASE WHEN COALESCE(v_wants_emoji, FALSE)
                               THEN v_row.reaction END
            ))
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
