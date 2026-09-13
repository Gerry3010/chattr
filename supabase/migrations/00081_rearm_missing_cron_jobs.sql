-- SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
-- SPDX-License-Identifier: AGPL-3.0-or-later
--
-- Schedule the sweepers again — three of them NEVER ran, one was never scheduled
-- anywhere.
--
-- ---------------------------------------------------------------------------
-- Finding (2026-08-23, measured against the prod database)
-- ---------------------------------------------------------------------------
-- `cron.job` contained exactly ONE entry: purge-dormant-accounts (00077).
-- Missing were:
--   * cleanup_old_messages()      — was never scheduled in ANY migration
--   * delete-expired-messages     (00014, self-destruct)
--   * cleanup-recovery-challenges (00050)
--   * cleanup-old-media           (00018)
--
-- The consequence in numbers: 4,773 message rows, the oldest from 2026-02-12 — with
-- an intended retention of 7 days. 4,091 of them had been read and were older than
-- seven days, so they should long since have been deleted. The content was gone
-- (`mark_message_received` clears that on delivery); what remained was the row around
-- it: chat_id, sender_id, recipient_id, created_at, received_at, read_at. That is
-- half a year of an unbroken communication graph — who with whom, when, how often, in
-- which direction. Precisely what 00062 set out to stop. Plus 2 overdue self-destruct
-- messages and 2.4 GB of media the reaper never touched.
--
-- ---------------------------------------------------------------------------
-- The cause — and why nobody noticed
-- ---------------------------------------------------------------------------
-- 00014, 00018 and 00050 all check:
--
--     IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron')
--
-- so "is the extension ALREADY INSTALLED". It was not at the time. The block then did
-- nothing — without an ELSE, without a RAISE, without an error. The migration ran
-- green, and migrations do not run again.
--
-- 00077 later did it right: it checks `pg_available_extensions` (is it INSTALLABLE)
-- and creates it itself. Since then pg_cron has been there — but only the job 00077
-- scheduled itself.
--
-- The punchline is delivered by 00045: there `EXECUTE` on exactly these functions was
-- revoked from PUBLIC, on the grounds that they "run via pg_cron as postgres". The
-- safeguard rested on an assumption that was already false at that point. Nobody was
-- allowed to call the functions, and nobody did.
--
-- A LESSON beyond this file: a conditional block that STAYS SILENT when unsatisfied
-- reports success. Every branch here therefore says out loud what it did or left
-- undone.
--
-- ---------------------------------------------------------------------------
-- ⚠️ What the first run does
-- ---------------------------------------------------------------------------
-- It catches up on half a year of backlog at once:
--   * ~4,000 message rows disappear. No message loss — the decrypted text lies on
--     the devices. Senders lose the delivery/read status of old messages
--     (get_sent_message_status works off a client-side watermark and tolerates
--     missing rows).
--   * Media that all recipients have fetched is cleared away (00056) — older
--     pictures/videos will then no longer load in the chats. That is the promised
--     behaviour, but after six months of no cleanup it shows. Take a backup BEFORE
--     the first run.
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  v_geplant text[] := ARRAY[]::text[];
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
    RAISE WARNING 'pg_cron ist auf dieser Instanz nicht verfügbar — KEIN Aufräumer eingeplant. Die Funktionen müssen extern gerufen werden.';
    RETURN;
  END IF;

  EXECUTE 'CREATE EXTENSION IF NOT EXISTS pg_cron';

  -- 1) Message metadata. The most important one, and the one that never
  -- existed. 03:23 UTC, an odd minute, away from the 04:17 group.
  PERFORM cron.unschedule('cleanup-old-messages')
    WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'cleanup-old-messages');
  PERFORM cron.schedule('cleanup-old-messages', '23 3 * * *',
                        'SELECT public.cleanup_old_messages()');
  v_geplant := v_geplant || 'cleanup-old-messages (täglich 03:23)'::text;

  -- 2) Self-destruct. Every minute — a promise that holds to the minute.
  PERFORM cron.unschedule('delete-expired-messages')
    WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'delete-expired-messages');
  PERFORM cron.schedule('delete-expired-messages', '* * * * *',
                        'SELECT public.delete_expired_messages()');
  v_geplant := v_geplant || 'delete-expired-messages (minütlich)'::text;

  -- 3) Abgelaufene Wiederherstellungs-Aufgaben.
  PERFORM cron.unschedule('cleanup-recovery-challenges')
    WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'cleanup-recovery-challenges');
  PERFORM cron.schedule('cleanup-recovery-challenges', '*/10 * * * *',
                        'DELETE FROM public.recovery_challenges WHERE expires_at < now()');
  v_geplant := v_geplant || 'cleanup-recovery-challenges (alle 10 min)'::text;

  -- 4) Media reaper (edge function). Needs pg_net + two vault secrets. If
  -- something is missing, that is REPORTED rather than concealed — exactly the
  -- fault that made this migration necessary.
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net')
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
    v_geplant := v_geplant || 'cleanup-old-media (täglich 04:17)'::text;
  ELSE
    RAISE WARNING 'cleanup-old-media NICHT eingeplant: pg_net oder die Vault-Geheimnisse (project_url / service_role_key) fehlen. Medien werden dann nicht abgeräumt.';
  END IF;

  RAISE NOTICE 'Eingeplant: %', array_to_string(v_geplant, ', ');
END $$;

-- Verification after applying (should return 5 rows): SELECT jobname, schedule,
-- active FROM cron.job ORDER BY jobname;
