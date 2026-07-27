-- ============================================================================
-- 00018: Media retention — hard 3-month limit
-- ----------------------------------------------------------------------------
-- Encrypted media blobs in the private `media` bucket are removed 3 months
-- after upload (hard limit for now). Supabase forbids direct SQL DELETE from
-- storage.objects (protect_delete trigger), so the actual deletion runs through
-- the Storage API in the `cleanup-old-media` Edge Function. This migration:
--   1. provides a read-only helper to list what's due (testable in SQL), and
--   2. schedules a daily call to the Edge Function via pg_cron + pg_net.
--
-- The referencing message rows are already pruned by cleanup_old_messages, so
-- by 3 months only the storage objects could linger.
-- ============================================================================

-- Read-only: which media objects are past the 3-month retention limit.
CREATE OR REPLACE FUNCTION media_objects_to_reap()
RETURNS TABLE(name text)
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE sql
AS $$
  SELECT o.name
  FROM storage.objects o
  WHERE o.bucket_id = 'media'
    AND o.created_at < now() - interval '3 months';
$$;

COMMENT ON FUNCTION media_objects_to_reap IS
  'Lists media-bucket objects older than 3 months (the cleanup-old-media Edge Function deletes them).';

-- Schedule the Edge Function daily. Guarded for environments without pg_cron /
-- pg_net / the required vault secrets (project_url + service_role_key, set by
-- setup-env). No-op where unavailable.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron')
     AND EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net')
     AND EXISTS (SELECT 1 FROM vault.decrypted_secrets WHERE name = 'project_url')
     AND EXISTS (SELECT 1 FROM vault.decrypted_secrets WHERE name = 'service_role_key')
  THEN
    PERFORM cron.unschedule('cleanup-old-media')
      WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'cleanup-old-media');
    PERFORM cron.schedule(
      'cleanup-old-media',
      '17 4 * * *',
      $cron$
        SELECT net.http_post(
          url := (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'project_url')
                 || '/functions/v1/cleanup-old-media',
          headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'Authorization', 'Bearer ' ||
              (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'service_role_key')
          )
        );
      $cron$
    );
  END IF;
END;
$$;
