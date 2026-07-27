-- ============================================================================
-- 00056: Media retention v3 — reap a blob once EVERY recipient has downloaded
-- ----------------------------------------------------------------------------
-- Until now a media blob's life was coupled to READ receipts: media_objects_to_reap
-- (00034) only dropped a blob after cleanup_old_messages pruned the message rows,
-- which happens at read_at+7d (or unreceived+30d). Two gaps followed:
--   1. A recipient with read receipts OFF never sets read_at → the "read+7d" rule
--      never fires → the blob lingers until the 3-month hard cap. One such
--      recipient keeps the blob alive for up to 3 months.
--   2. Even with receipts on, the blob sat ~7 days longer than needed after the
--      last recipient had already fetched it.
--
-- Fix: a media-specific "downloaded by recipient" signal, DECOUPLED from read
-- receipts. Each recipient confirms (via mark_media_downloaded) after it has
-- fetched + decrypted the blob; the reaper drops the blob as soon as every
-- recipient (excluding the sender's own copy) has confirmed — regardless of the
-- read-receipt setting. The 24h grace and the 3-month hard cap are unchanged.
--
-- This is the same signal the planned admin dashboard's "not yet fetched" metric
-- will read.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Per-recipient download confirmations. Mirrors the composite-PK-per-recipient
-- shape of `messages`. No FK to messages (those rows are pruned on their own
-- schedule); orphans are swept in cleanup_old_messages below.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.media_downloads (
  message_id    UUID NOT NULL,
  recipient_id  UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  downloaded_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (message_id, recipient_id)
);

-- Only the SECURITY DEFINER RPC (and the service_role reaper) touch this table;
-- no direct client DML. RLS on with no policies denies authenticated/anon.
ALTER TABLE public.media_downloads ENABLE ROW LEVEL SECURITY;

-- ----------------------------------------------------------------------------
-- mark_media_downloaded — a recipient confirms it has fetched + decrypted the
-- blob for a message. Idempotent; silently no-ops for non-members (fire-and-
-- forget from the client). Models mark_message_received (00002) but records a
-- separate signal instead of clearing content.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION mark_media_downloaded(
  p_message_id UUID,
  p_chat_id UUID
)
RETURNS VOID
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE sql
AS $$
  INSERT INTO public.media_downloads (message_id, recipient_id)
  SELECT p_message_id, auth.uid()
  WHERE EXISTS (
    SELECT 1 FROM public.chat_members cm
    WHERE cm.chat_id = p_chat_id
      AND cm.user_id = auth.uid()
  )
  ON CONFLICT (message_id, recipient_id) DO NOTHING;
$$;

COMMENT ON FUNCTION mark_media_downloaded IS
  'Records that the calling recipient has downloaded+decrypted a media blob (decoupled from read receipts). Idempotent; no-ops for non-members.';

REVOKE ALL ON FUNCTION mark_media_downloaded(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION mark_media_downloaded(uuid, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION mark_media_downloaded(uuid, uuid) TO authenticated;

-- ----------------------------------------------------------------------------
-- media_objects_to_reap — add a "downloaded-by-all" pass to 00034. A blob is now
-- reaped when EITHER (unchanged): older than 3 months, OR unreferenced by any
-- message row after 24h; OR (new): every recipient row for its message has a
-- matching media_downloads confirmation (after the same 24h grace).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION media_objects_to_reap()
RETURNS TABLE(name text)
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE sql
AS $$
  SELECT o.name
  FROM storage.objects o
  WHERE o.bucket_id = 'media'
    AND (
      -- Hard age fallback (unchanged from 00018/00034).
      o.created_at < now() - interval '3 months'
      OR (
        -- Unreferenced: no message row with that id exists anymore (00034).
        o.created_at < now() - interval '24 hours'
        AND split_part(o.name, '/', 2) ~
          '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'
        AND NOT EXISTS (
          SELECT 1 FROM public.messages m
          WHERE m.id = split_part(o.name, '/', 2)::uuid
        )
      )
      OR (
        -- Downloaded-by-all: every recipient (excluding the sender's own copy)
        -- has confirmed a download → the blob is on every device, drop it early,
        -- independent of read receipts. Requires ≥1 recipient row so we never
        -- reap on a vacuously-true empty set (that path is the unreferenced pass).
        o.created_at < now() - interval '24 hours'
        AND split_part(o.name, '/', 2) ~
          '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'
        AND EXISTS (
          SELECT 1 FROM public.messages m
          WHERE m.id = split_part(o.name, '/', 2)::uuid
            AND m.recipient_id IS DISTINCT FROM m.sender_id
        )
        AND NOT EXISTS (
          SELECT 1 FROM public.messages m
          WHERE m.id = split_part(o.name, '/', 2)::uuid
            AND m.recipient_id IS DISTINCT FROM m.sender_id
            AND NOT EXISTS (
              SELECT 1 FROM public.media_downloads d
              WHERE d.message_id = m.id
                AND d.recipient_id = m.recipient_id
            )
        )
      )
    );
$$;

COMMENT ON FUNCTION media_objects_to_reap IS
  'Lists media-bucket objects due for deletion: downloaded by all recipients (24h grace, receipt-independent), unreferenced by any message row (24h grace), or older than the 3-month hard limit. Consumed via RPC by the cleanup-old-media Edge Function.';

REVOKE EXECUTE ON FUNCTION media_objects_to_reap() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION media_objects_to_reap() FROM anon;
REVOKE EXECUTE ON FUNCTION media_objects_to_reap() FROM authenticated;
GRANT EXECUTE ON FUNCTION media_objects_to_reap() TO service_role;

-- ----------------------------------------------------------------------------
-- cleanup_old_messages — unchanged retention windows, plus a sweep of orphaned
-- media_downloads rows (their message has been pruned) so the table can't grow
-- unbounded.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cleanup_old_messages()
RETURNS INTEGER
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
DECLARE
  deleted_read_count INTEGER;
  deleted_unread_count INTEGER;
  total_deleted INTEGER;
BEGIN
  -- Delete messages that have been read and are older than 7 days
  DELETE FROM messages
  WHERE read_at IS NOT NULL
    AND read_at < NOW() - INTERVAL '7 days';

  GET DIAGNOSTICS deleted_read_count = ROW_COUNT;

  -- Delete messages that haven't been received/read and are older than 30 days
  DELETE FROM messages
  WHERE received_at IS NULL
    AND created_at < NOW() - INTERVAL '30 days';

  GET DIAGNOSTICS deleted_unread_count = ROW_COUNT;

  -- Sweep download confirmations whose message is gone (orphans).
  DELETE FROM media_downloads d
  WHERE NOT EXISTS (
    SELECT 1 FROM messages m WHERE m.id = d.message_id
  );

  total_deleted := deleted_read_count + deleted_unread_count;

  RAISE NOTICE 'Message cleanup: deleted % read messages (>7 days) and % unread messages (>30 days). Total: %',
    deleted_read_count, deleted_unread_count, total_deleted;

  RETURN total_deleted;
END;
$$;

COMMENT ON FUNCTION cleanup_old_messages IS
  'Deletes read messages older than 7 days and unread/unreceived messages older than 30 days, and sweeps orphaned media_downloads rows.';
