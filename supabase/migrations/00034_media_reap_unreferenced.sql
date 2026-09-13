-- ============================================================================
-- 00034: Media retention v2 — reap blobs once every recipient has read
-- ----------------------------------------------------------------------------
-- Extends media_objects_to_reap() (00018) with an "unreferenced" pass: a blob
-- whose message rows are ALL gone (cleanup_old_messages pruned them — every
-- recipient read the message ≥7 days ago, or it sat unread for 30 days) no
-- longer has any reachable media key and is deleted early instead of waiting
-- out the 90-day fallback.
--
-- Delivery alone must NOT reap: recipients decrypt the envelope (incl. the
-- media key) on receipt but download the blob lazily on first view — the
-- read+7d window from cleanup_old_messages is their chance to still fetch it.
-- A 24h minimum age protects uploads whose message rows land moments after
-- the blob (send in flight).
--
-- Also fixes the Edge Function integration: PostgREST does not expose the
-- storage schema, so cleanup-old-media's previous direct query on
-- storage.objects always failed — it now calls THIS function via RPC.
-- ============================================================================

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
      -- Hard age fallback (unchanged from 00018).
      o.created_at < now() - interval '3 months'
      OR (
        -- Unreferenced: object path is <chatId>/<messageId>/<file>.enc and
        -- no message row with that id exists anymore.
        o.created_at < now() - interval '24 hours'
        AND split_part(o.name, '/', 2) ~
          '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'
        AND NOT EXISTS (
          SELECT 1 FROM public.messages m
          WHERE m.id = split_part(o.name, '/', 2)::uuid
        )
      )
    );
$$;

COMMENT ON FUNCTION media_objects_to_reap IS
  'Lists media-bucket objects due for deletion: unreferenced by any message row (all recipients read, rows pruned) after a 24h grace, or older than the 3-month hard limit. Consumed via RPC by the cleanup-old-media Edge Function.';

-- Only the scheduled service-role caller needs this.
REVOKE EXECUTE ON FUNCTION media_objects_to_reap() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION media_objects_to_reap() FROM anon;
REVOKE EXECUTE ON FUNCTION media_objects_to_reap() FROM authenticated;
GRANT EXECUTE ON FUNCTION media_objects_to_reap() TO service_role;
