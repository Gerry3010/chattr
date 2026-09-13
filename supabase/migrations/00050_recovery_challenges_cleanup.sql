-- 00050_recovery_challenges_cleanup.sql
--
-- Bound the `recovery_challenges` table (audit L4). The anon-callable
-- `recover-identity` (action:"challenge") inserts one row per DISTINCT recovery
-- public key and only ever deletes a row on the matching `verify` — so
-- never-verified challenges (an attacker spamming random keys) lingered past
-- their 120 s TTL forever, an unbounded storage-exhaustion vector. There was
-- also no index on `expires_at`.
--
-- Fix: index the TTL column and schedule a periodic sweep of expired rows. The
-- edge function now also caps outstanding challenges (MAX_OUTSTANDING_CHALLENGES)
-- for the in-flight window; this migration bounds the long tail. Pure SQL — no
-- edge function / pg_net / vault secret needed, only pg_cron (guarded, no-op
-- where unavailable, mirroring 00018_media_retention).

CREATE INDEX IF NOT EXISTS idx_recovery_challenges_expires
  ON recovery_challenges (expires_at);

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule('cleanup-recovery-challenges')
      WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'cleanup-recovery-challenges');
    PERFORM cron.schedule(
      'cleanup-recovery-challenges',
      '*/10 * * * *',
      $cron$ DELETE FROM public.recovery_challenges WHERE expires_at < now(); $cron$
    );
  END IF;
END;
$$;
