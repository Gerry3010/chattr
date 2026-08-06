-- =====================================================
-- Private Realtime-Topics (Metadaten-Audit 2026-08-02, Fund C1)
-- =====================================================
-- Jeder `realtime.send(...)` in diesem Projekt hat `private => FALSE` gesetzt,
-- und auf `realtime.messages` gab es keine einzige RLS-Policy. Am lokalen Stack
-- reproduziert: ein FRISCH ANONYM angemeldeter Nutzer abonniert
-- `user:<fremde-uuid>` und bekommt `SUBSCRIBED` plus den kompletten Payload —
-- chat_id, sender_id, message_id, Zeitstempel, Reply-Graph, Reaktionen,
-- Mitgliederwechsel. Der Inhalt bleibt Chiffrat, aber der Metadaten-Feed eines
-- Fremden ist live mitlesbar. User-UUIDs sind über die öffentlichen
-- Avatar-Buckets enumerierbar, also ist das kein theoretischer Angriff.
--
-- Fix: gespiegelter Versand auf einen PRIVATEN Topic (`p:` + alter Name), der
-- über eine RLS-Policy auf `realtime.messages` nur dem Eigentümer gehört.
--
-- WARUM DOPPELT GESENDET WIRD: ein `private:true`-Abonnent sieht keine
-- öffentlichen Broadcasts und umgekehrt. Ein harter Umschalter würde jeden
-- noch nicht aktualisierten Client stumm schalten (er würde nur noch beim
-- App-Resume nachsynchronisieren). Deshalb sendet diese Migration eine
-- Übergangszeit lang auf BEIDE Topics. Sobald die Flotte durch ist, wird in
-- `chattr_send` die Legacy-Zeile gelöscht — eine Zeile, eine Migration.
--
-- Der Trick beim Umbau: `chattr_send` hat exakt DIESELBE Signatur wie
-- `realtime.send`, deshalb ist der Eingriff in die 12 Trigger-Funktionen ein
-- reines Ersetzen des Funktionsnamens — keine Umstellung der Argumente, kein
-- Regex auf mehrzeiligem SQL. Die Definitionen unten sind mit
-- `pg_get_functiondef` aus der migrierten Datenbank gezogen (also der
-- TATSÄCHLICHE Stand nach allen Überschreibungen), nicht aus den
-- Ursprungs-Migrationen zusammengesucht.

-- ---------------------------------------------------------------------------
-- Helper: sendet auf den Legacy-Topic UND den privaten Spiegel
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.chattr_send(
  payload JSONB,
  event TEXT,
  topic TEXT,
  private BOOLEAN DEFAULT FALSE
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
BEGIN
  -- Legacy, öffentlich: hält Clients vor dieser Version am Leben.
  -- ENTFERNEN, sobald die Flotte auf privaten Topics ist.
  PERFORM realtime.send(payload, event, topic, private);

  -- Privater Spiegel: nur der Eigentümer darf ihn lesen (Policy unten).
  PERFORM realtime.send(payload, event, 'p:' || topic, TRUE);
END;
$$;

COMMENT ON FUNCTION public.chattr_send IS
  'Broadcast-Helfer mit derselben Signatur wie realtime.send. Sendet in der Uebergangsphase auf den oeffentlichen Legacy-Topic UND auf den privaten Spiegel (p:<topic>). Nach dem Flotten-Rollout die Legacy-Zeile entfernen.';

-- ---------------------------------------------------------------------------
-- RLS: der private Topic gehoert genau seinem Nutzer
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "chattr own user topic" ON realtime.messages;
CREATE POLICY "chattr own user topic" ON realtime.messages
  FOR SELECT
  TO authenticated
  USING (realtime.topic() = 'p:user:' || auth.uid()::text);

-- ---------------------------------------------------------------------------
-- Trigger-Funktionen auf den Helfer umbiegen (Definitionen aus der DB gezogen)
-- ---------------------------------------------------------------------------

-- broadcast_member_key_registered
CREATE OR REPLACE FUNCTION public.broadcast_member_key_registered()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  member_record RECORD;
BEGIN
  -- Only the FIRST registration (NULL → value).
  IF NOT (OLD.public_key IS NULL AND NEW.public_key IS NOT NULL) THEN
    RETURN NEW;
  END IF;

  FOR member_record IN
    SELECT user_id
    FROM chat_members
    WHERE chat_id = NEW.chat_id
      AND user_id <> NEW.user_id
  LOOP
    PERFORM public.chattr_send(
      jsonb_build_object(
        'type', 'memberKeyRegistered',
        'chat_id', NEW.chat_id,
        'user_id', NEW.user_id,
        'timestamp', NOW()
      ),
      'event',
      'user:' || member_record.user_id,
      FALSE
    );
  END LOOP;

  RETURN NEW;
END;
$function$;

-- broadcast_new_chat_member
CREATE OR REPLACE FUNCTION public.broadcast_new_chat_member()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  -- Notify the new member about the chat they were added to
  PERFORM public.chattr_send(
    jsonb_build_object(
      'type', 'newChat',
      'chat_id', NEW.chat_id,
      'timestamp', NOW()
    ),
    'event',
    'user:' || NEW.user_id::text,
    FALSE
  );
  RETURN NEW;
END;
$function$;

-- notify_admins_pending_member
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
$function$;

-- notify_chat_delete
CREATE OR REPLACE FUNCTION public.notify_chat_delete()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  member_record RECORD;
BEGIN
  -- Notify all members of this chat
  FOR member_record IN
    SELECT user_id
    FROM chat_members
    WHERE chat_id = OLD.id
  LOOP
    PERFORM public.chattr_send(
      jsonb_build_object(
        'type', 'chatDeleted',
        'chat_id', OLD.id,
        'timestamp', NOW()
      ),
      'event',
      'user:' || member_record.user_id,
      FALSE
    );
  END LOOP;
  
  RETURN OLD;
END;
$function$;

-- notify_chat_deleted_on_member_removal
CREATE OR REPLACE FUNCTION public.notify_chat_deleted_on_member_removal()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  -- Send chatDeleted event to the removed user
  PERFORM public.chattr_send(
    jsonb_build_object(
      'type', 'chatDeleted',
      'chat_id', OLD.chat_id,
      'timestamp', NOW()
    ),
    'event',
    'user:' || OLD.user_id,
    FALSE
  );
  
  RETURN OLD;
END;
$function$;

-- notify_chat_update
CREATE OR REPLACE FUNCTION public.notify_chat_update()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  member_record RECORD;
  updates_json JSONB;
BEGIN
  -- Build updates object with only changed fields
  updates_json := jsonb_build_object();
  
  IF OLD.name IS DISTINCT FROM NEW.name THEN
    updates_json := updates_json || jsonb_build_object('name', NEW.name);
  END IF;
  
  IF OLD.admins IS DISTINCT FROM NEW.admins THEN
    updates_json := updates_json || jsonb_build_object('admins', NEW.admins);
  END IF;
  
  -- Only notify if something actually changed
  IF updates_json != '{}'::jsonb THEN
    -- Notify all members of this chat
    FOR member_record IN
      SELECT user_id
      FROM chat_members
      WHERE chat_id = NEW.id
    LOOP
      PERFORM public.chattr_send(
        jsonb_build_object(
          'type', 'chatUpdate',
          'chat_id', NEW.id,
          'updates', updates_json,
          'timestamp', NOW()
        ),
        'event',
        'user:' || member_record.user_id,
        FALSE
      );
    END LOOP;
  END IF;
  
  RETURN NEW;
END;
$function$;

-- notify_members_new_message
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
$function$;

-- notify_membership_change
CREATE OR REPLACE FUNCTION public.notify_membership_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  changed_user_id UUID;
  action TEXT;
  member_record RECORD;
  username_text TEXT;
BEGIN
  -- Determine action and affected user
  IF TG_OP = 'INSERT' THEN
    changed_user_id := NEW.user_id;
    action := 'joined';
  ELSIF TG_OP = 'DELETE' THEN
    changed_user_id := OLD.user_id;
    -- An authenticated session deleting SOMEONE ELSE's membership is an admin
    -- kick (RLS only lets admins do that). Self-delete and definer cascades
    -- (account deletion, cleanup) read as a plain leave.
    IF auth.uid() IS NOT NULL AND auth.uid() != OLD.user_id THEN
      action := 'removed';
    ELSE
      action := 'left';
    END IF;
  ELSE
    -- For UPDATE, we don't track anymore
    RETURN NEW;
  END IF;

  -- Get username for system message
  SELECT username INTO username_text
  FROM profiles
  WHERE id = changed_user_id;

  username_text := COALESCE(username_text, 'A user');

  -- Insert encrypted system message for all members
  PERFORM insert_system_message(
    COALESCE(NEW.chat_id, OLD.chat_id),
    action,
    changed_user_id,
    username_text
  );

  -- Notify all members of this chat (except the changed user)
  FOR member_record IN
    SELECT user_id
    FROM chat_members
    WHERE chat_id = COALESCE(NEW.chat_id, OLD.chat_id)
      AND user_id != changed_user_id
  LOOP
    PERFORM public.chattr_send(
      jsonb_build_object(
        'type', 'membershipChanged',
        'chat_id', COALESCE(NEW.chat_id, OLD.chat_id),
        'user_id', changed_user_id,
        'action', action,
        'timestamp', NOW()
      ),
      'event',
      'user:' || member_record.user_id,
      FALSE
    );
  END LOOP;

  RETURN COALESCE(NEW, OLD);
END;
$function$;

-- notify_message_delete
CREATE OR REPLACE FUNCTION public.notify_message_delete()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  member_record RECORD;
BEGIN
  -- Notify all members of this chat (except sender)
  FOR member_record IN
    SELECT user_id
    FROM chat_members
    WHERE chat_id = OLD.chat_id
      AND user_id != OLD.sender_id
  LOOP
    PERFORM public.chattr_send(
      jsonb_build_object(
        'type', 'messageDelete',
        'chat_id', OLD.chat_id,
        'message_id', OLD.id,
        'timestamp', NOW()
      ),
      'event',
      'user:' || member_record.user_id,
      FALSE
    );
  END LOOP;
  
  RETURN OLD;
END;
$function$;

-- notify_message_update
CREATE OR REPLACE FUNCTION public.notify_message_update()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  updates_json JSONB;
BEGIN
  -- 1) Status changes (received/read) → notify the sender (read receipts).
  updates_json := jsonb_build_object();

  IF OLD.received_at IS DISTINCT FROM NEW.received_at THEN
    updates_json := updates_json || jsonb_build_object('received_at', NEW.received_at);
  END IF;

  IF OLD.read_at IS DISTINCT FROM NEW.read_at THEN
    updates_json := updates_json || jsonb_build_object('read_at', NEW.read_at);
  END IF;

  IF updates_json != '{}'::jsonb AND NEW.sender_id IS NOT NULL THEN
    PERFORM public.chattr_send(
      jsonb_build_object(
        'type', 'messageUpdate',
        'chat_id', NEW.chat_id,
        'message_id', NEW.id,
        'recipient_id', NEW.recipient_id,
        'updates', updates_json,
        'timestamp', NOW()
      ),
      'event',
      'user:' || NEW.sender_id,
      FALSE
    );
  END IF;

  -- 2) Content edit → notify the recipient so they re-fetch + re-decrypt.
  --    Only when the ciphertext changed to a non-empty value: the clear that
  --    happens on read/receive sets it to '' / NULL and must NOT be treated as
  --    an edit (and must not be sent back to the recipient as new content).
  IF OLD.encrypted_content IS DISTINCT FROM NEW.encrypted_content
     AND COALESCE(NEW.encrypted_content, '') <> ''
     AND NEW.recipient_id IS NOT NULL
     AND NEW.recipient_id <> NEW.sender_id THEN
    PERFORM public.chattr_send(
      jsonb_build_object(
        'type', 'messageUpdate',
        'chat_id', NEW.chat_id,
        'message_id', NEW.id,
        'recipient_id', NEW.recipient_id,
        'updates', jsonb_build_object('content_changed', true),
        'timestamp', NOW()
      ),
      'event',
      'user:' || NEW.recipient_id,
      FALSE
    );
  END IF;

  RETURN NEW;
END;
$function$;

-- notify_profile_change
CREATE OR REPLACE FUNCTION public.notify_profile_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
    PERFORM public.chattr_send(
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
$function$;

-- notify_reaction_change
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
$function$;
