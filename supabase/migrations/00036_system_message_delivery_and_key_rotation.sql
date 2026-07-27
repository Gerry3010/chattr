-- ============================================================================
-- 00036: System messages — fix delivery (visibility race), announce key rotation
-- ----------------------------------------------------------------------------
-- (A) Why system messages never arrived (prod showed 0 rows since deploy):
--     insert_system_message called the Edge Function SYNCHRONOUSLY via
--     extensions.http() from INSIDE the triggering transaction, while the
--     function loaded chat_members from OUTSIDE via PostgREST. Snapshot
--     isolation means it could not see the not-yet-committed membership
--     rows — for the first member of a fresh chat it saw an empty chat
--     (edge logs: member_keys {}), so zero recipient rows were written.
--     Fix: build member_keys inside the trigger's own snapshot (which DOES
--     see the triggering row) and pass them in the request body; deliver
--     async AFTER COMMIT via pg_net like the (working) push chain. Members
--     whose public_key is still NULL (key registered client-side moments
--     after joining) are skipped — the join announcement is for the
--     EXISTING members anyway.
--
-- (B) "Schlüssel neu erzeugen" gets an announcement: real rotations
--     (existing key replaced by a different one) post a 'keys_rotated'
--     system message. Initial key registration (NULL → key) and idempotent
--     re-writes of the same key stay silent.
-- ============================================================================

CREATE OR REPLACE FUNCTION insert_system_message(
  p_chat_id UUID,
  p_action TEXT,
  p_subject_id UUID,
  p_subject_name TEXT
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
        'member_keys', v_member_keys
      )
    );
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'insert_system_message: pg_net call failed: %', SQLERRM;
  END;
END;
$$;

COMMENT ON FUNCTION insert_system_message IS
  'Queues the insert-system-message Edge Function call via pg_net, passing member_keys from the trigger''s own snapshot ({action, subject_id, subject_name} JSON payload).';

-- ─── (B) keys_rotated announcement ──────────────────────────────────────────

CREATE OR REPLACE FUNCTION notify_key_rotation()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql
AS $$
DECLARE
  username_text TEXT;
BEGIN
  -- Only a real rotation: an existing key replaced by a different one.
  -- Initial registration (NULL → key) and same-value re-writes are silent.
  IF OLD.public_key IS NULL
     OR NEW.public_key IS NULL
     OR OLD.public_key = NEW.public_key THEN
    RETURN NEW;
  END IF;

  SELECT username INTO username_text FROM profiles WHERE id = NEW.user_id;

  PERFORM insert_system_message(
    NEW.chat_id,
    'keys_rotated',
    NEW.user_id,
    COALESCE(username_text, 'A user')
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS notify_key_rotation_trigger ON chat_members;
CREATE TRIGGER notify_key_rotation_trigger
  AFTER UPDATE OF public_key ON chat_members
  FOR EACH ROW
  EXECUTE FUNCTION notify_key_rotation();

COMMENT ON FUNCTION notify_key_rotation IS
  'Posts a keys_rotated system message when a member replaces their chat key pair (Schlüssel neu erzeugen).';
