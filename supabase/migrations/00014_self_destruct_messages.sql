-- ============================================================================
-- 00014: Self-destructing (ephemeral) messages
-- ----------------------------------------------------------------------------
-- Stage 8.2 — disappearing messages, configured per chat. When a chat has
-- `message_ttl_seconds` set, every message sent in it gets an `expires_at`
-- (created_at + ttl). A pg_cron job deletes expired rows server-side; the
-- existing BEFORE DELETE trigger (notify_message_delete) then propagates a
-- messageDelete event so every client removes it locally too. Clients also
-- sweep their own decrypted local store on chat open.
-- ============================================================================

-- Per-chat TTL: NULL = disabled. Stored in seconds.
ALTER TABLE chats
  ADD COLUMN IF NOT EXISTS message_ttl_seconds integer
  CHECK (message_ttl_seconds IS NULL OR message_ttl_seconds > 0);

COMMENT ON COLUMN chats.message_ttl_seconds IS
  'Disappearing-messages TTL in seconds for this chat. NULL = disabled.';

-- When a message expires (per-recipient rows all carry the same value).
ALTER TABLE messages
  ADD COLUMN IF NOT EXISTS expires_at timestamptz;

COMMENT ON COLUMN messages.expires_at IS
  'When this message self-destructs. NULL = never. Set from the chat TTL on send.';

CREATE INDEX IF NOT EXISTS idx_messages_expires_at
  ON messages (expires_at)
  WHERE expires_at IS NOT NULL;

-- Server-side reaper. SECURITY DEFINER so the cron job (no auth context) can
-- delete across all chats; the DELETE fires notify_message_delete per row.
-- NOTE: search_path is set to `public` (not '') on purpose: the DELETE fires
-- the existing BEFORE DELETE trigger notify_message_delete(), which references
-- unqualified `chat_members`. A trigger with no explicit search_path inherits
-- the caller's, so an empty search_path here would break it.
CREATE OR REPLACE FUNCTION delete_expired_messages()
RETURNS integer
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql
AS $$
DECLARE
  deleted_count integer;
BEGIN
  WITH del AS (
    DELETE FROM public.messages
    WHERE expires_at IS NOT NULL AND expires_at < now()
    RETURNING 1
  )
  SELECT count(*) INTO deleted_count FROM del;

  IF deleted_count > 0 THEN
    RAISE NOTICE 'Self-destruct: deleted % expired message rows.', deleted_count;
  END IF;
  RETURN deleted_count;
END;
$$;

COMMENT ON FUNCTION delete_expired_messages IS
  'Deletes messages whose expires_at has passed (disappearing messages).';

-- Schedule the reaper once a minute when pg_cron is present. Guarded so the
-- migration still applies in environments without pg_cron.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule('delete-expired-messages')
      WHERE EXISTS (
        SELECT 1 FROM cron.job WHERE jobname = 'delete-expired-messages'
      );
    PERFORM cron.schedule(
      'delete-expired-messages',
      '* * * * *',
      $cron$ SELECT public.delete_expired_messages(); $cron$
    );
  END IF;
END;
$$;
