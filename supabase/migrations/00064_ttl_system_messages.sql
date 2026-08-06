-- SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
-- SPDX-License-Identifier: AGPL-3.0-or-later

-- ============================================================================
-- 00064: Announce disappearing-messages (self-destruct) changes
-- ----------------------------------------------------------------------------
-- Turning self-destruct on or off silently changed the rules for EVERYONE in
-- the chat: from that moment on your messages start expiring (or stop), and
-- nobody but the admin who flipped it had any way to find out. Every other
-- membership/security change already announces itself as a system message —
-- this one is arguably the most consequential and did not.
--
-- (A) insert_system_message gains an optional `p_detail` argument. The TTL
--     announcement needs a second value (the duration) that does not fit into
--     `subject_name`, and it is passed as RAW SECONDS, not a rendered string:
--     the client formats it in its own locale ("5 Minuten" / "5 minutes").
--     The 4-arg version is dropped and replaced by a 5-arg one with a DEFAULT
--     — keeping both would make every existing 4-arg call site ambiguous.
--     All callers are plpgsql trigger functions (late-bound), so they resolve
--     to the new signature without being touched. The 00045 REVOKE is
--     re-applied: dropping the function took its (absent) grants with it, and
--     a freshly created function is EXECUTE-able by PUBLIC again by default —
--     forgetting this line would silently re-open the system-message forgery
--     hole that 00045 closed (finding H4).
--
-- (B) notify_message_ttl_change: AFTER UPDATE OF message_ttl_seconds ON chats.
--     NULL → value  = 'ttl_enabled'  (detail = seconds)
--     value → NULL  = 'ttl_disabled'
--     value → other = 'ttl_enabled'  (re-announced with the new duration)
-- ============================================================================

-- ─── (A) insert_system_message with an optional detail argument ─────────────

DROP FUNCTION IF EXISTS public.insert_system_message(uuid, text, uuid, text);

CREATE OR REPLACE FUNCTION insert_system_message(
  p_chat_id UUID,
  p_action TEXT,
  p_subject_id UUID,
  p_subject_name TEXT,
  p_detail TEXT DEFAULT NULL
)
RETURNS VOID
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql
AS $$
DECLARE
  function_url TEXT;
  v_member_keys JSONB;
BEGIN
  function_url := COALESCE(
    current_setting('app.settings.edge_function_url', true),
    'http://kong:8000/functions/v1/insert-system-message'
  );

  -- In-transaction snapshot: sees the membership change that fired the
  -- trigger, which the Edge Function's out-of-band PostgREST query cannot.
  SELECT jsonb_object_agg(user_id, public_key)
  INTO v_member_keys
  FROM chat_members
  WHERE chat_id = p_chat_id
    AND public_key IS NOT NULL;

  IF v_member_keys IS NULL THEN
    RAISE WARNING 'insert_system_message: no member keys for chat %, dropping % message', p_chat_id, p_action;
    RETURN;
  END IF;

  BEGIN
    -- pg_net queues the request and sends it after commit (responses land in
    -- net._http_response for debugging).
    PERFORM net.http_post(
      url := function_url,
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || private.get_secret('service_role_key')
      ),
      body := jsonb_build_object(
        'chat_id', p_chat_id::text,
        'action', p_action,
        'subject_id', p_subject_id::text,
        'subject_name', p_subject_name,
        'detail', p_detail,
        'member_keys', v_member_keys
      )
    );
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'insert_system_message: pg_net call failed: %', SQLERRM;
  END;
END;
$$;

COMMENT ON FUNCTION insert_system_message IS
  'Queues the insert-system-message Edge Function call via pg_net, passing member_keys from the trigger''s own snapshot ({action, subject_id, subject_name, detail} JSON payload). Trigger-only — see 00045.';

-- Re-apply the 00045 revoke: the DROP above discarded the old function's
-- privileges and CREATE grants EXECUTE to PUBLIC by default.
REVOKE EXECUTE ON FUNCTION public.insert_system_message(uuid, text, uuid, text, text)
  FROM PUBLIC, anon, authenticated, service_role;

-- ─── (B) self-destruct announcement ─────────────────────────────────────────

CREATE OR REPLACE FUNCTION notify_message_ttl_change()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql
AS $$
DECLARE
  username_text TEXT;
  v_actor UUID;
BEGIN
  -- UPDATE OF fires on any write to the column, including a no-op re-save.
  -- IS NOT DISTINCT FROM so NULL = NULL counts as unchanged.
  IF NEW.message_ttl_seconds IS NOT DISTINCT FROM OLD.message_ttl_seconds THEN
    RETURN NEW;
  END IF;

  -- Normally the admin who used the picker. NULL for a service-role or
  -- maintenance write — announce it anyway (the change is real either way),
  -- just without a name.
  v_actor := auth.uid();
  IF v_actor IS NOT NULL THEN
    SELECT username INTO username_text FROM profiles WHERE id = v_actor;
  END IF;

  IF NEW.message_ttl_seconds IS NULL THEN
    PERFORM insert_system_message(
      NEW.id,
      'ttl_disabled',
      v_actor,
      COALESCE(username_text, 'A user'),
      NULL
    );
  ELSE
    PERFORM insert_system_message(
      NEW.id,
      'ttl_enabled',
      v_actor,
      COALESCE(username_text, 'A user'),
      NEW.message_ttl_seconds::text
    );
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS notify_message_ttl_change_trigger ON chats;
CREATE TRIGGER notify_message_ttl_change_trigger
  AFTER UPDATE OF message_ttl_seconds ON chats
  FOR EACH ROW
  EXECUTE FUNCTION notify_message_ttl_change();

COMMENT ON FUNCTION notify_message_ttl_change IS
  'Posts a ttl_enabled/ttl_disabled system message when a chat''s disappearing-messages TTL changes (detail = TTL in seconds, formatted client-side).';
