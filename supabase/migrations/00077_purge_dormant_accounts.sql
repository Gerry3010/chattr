-- SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
-- SPDX-License-Identifier: AGPL-3.0-or-later
--
-- Remove dormant accounts automatically.
--
-- Why: the app demands a username before one can see anything, and
-- `loginWithUsername` ALWAYS creates a new anonymous account in the process. So
-- whoever merely looks in via the public TestFlight link creates an account,
-- finds an empty app and is gone. What was left behind was a profile, an
-- identity key and a dead push token — on 2026-08-16 that was 47 of 54 iOS
-- devices, 1-5 new ones daily. That distorts every metric, holds rollout gates
-- open (such accounts never report an app version) and has the push service
-- serving dead tokens.
--
-- It fits the server's basic stance: it forgets what it does not need. An
-- account that has done nothing for three months and never HAD done anything is
-- data without a purpose.
--
-- ⚠️ The criteria are deliberately strict: ANY trace of use protects. An
-- account that was in a chat, sent OR RECEIVED a message, created a chat,
-- created an invitation, reported or was reported, or whose device has checked
-- in within the last three months, is NOT touched — even if it otherwise looks
-- dormant.
--
-- ⚠️ `messages.recipient_id` hangs on `auth.users` via ON DELETE CASCADE
-- (00001:99). A deleted account takes received messages with it. That is why
-- "has never received anything" is a criterion of its own and not an inference.

-- ---------------------------------------------------------------------------
-- The sweeper.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.purge_dormant_accounts(
  p_age         interval DEFAULT interval '3 months',
  p_dry_run     boolean  DEFAULT false,
  p_max_delete  integer  DEFAULT 200,   -- absolute Obergrenze pro Lauf
  p_max_percent integer  DEFAULT 50     -- … und nie mehr als dieser Anteil
)
RETURNS integer
SECURITY DEFINER
SET search_path = public, auth, pg_temp
LANGUAGE plpgsql
AS $$
DECLARE
  v_cutoff  timestamptz := now() - p_age;
  v_ids     uuid[];
  v_n       integer;
  v_total   integer;
BEGIN
  SELECT array_agg(p.id) INTO v_ids
  FROM public.profiles p
  WHERE p.created_at < v_cutoff
    AND (p.last_active_date IS NULL OR p.last_active_date < v_cutoff::date)
    -- war nie irgendwo dabei
    AND NOT EXISTS (SELECT 1 FROM public.chat_members         cm WHERE cm.user_id = p.id)
    AND NOT EXISTS (SELECT 1 FROM public.pending_chat_members pm WHERE pm.user_id = p.id)
    AND NOT EXISTS (SELECT 1 FROM public.chats                c  WHERE c.created_by = p.id)
    AND NOT EXISTS (SELECT 1 FROM public.chat_invites         ci WHERE ci.created_by = p.id)
    -- hat nie gesendet UND nie empfangen
    AND NOT EXISTS (SELECT 1 FROM public.messages m WHERE m.sender_id    = p.id)
    AND NOT EXISTS (SELECT 1 FROM public.messages m WHERE m.recipient_id = p.id)
    AND NOT EXISTS (SELECT 1 FROM public.message_reactions r WHERE r.user_id = p.id)
    -- Moderationsspuren bleiben erhalten, sie sind Beweismaterial
    AND NOT EXISTS (SELECT 1 FROM public.reports rp
                    WHERE rp.reporter_id = p.id OR rp.reported_user_id = p.id)
    -- and no device has checked in recently
    AND NOT EXISTS (SELECT 1 FROM public.device_tokens d
                    WHERE d.user_id = p.id AND d.updated_at >= v_cutoff);

  v_n := coalesce(array_length(v_ids, 1), 0);
  IF v_n = 0 THEN
    RETURN 0;
  END IF;

  -- The rip cord. If the run suddenly hits a large part of the user base, the
  -- criteria no longer hold (a new table, a renamed column, a NOT EXISTS that
  -- is always true after a schema change) — then aborting is right and deleting
  -- is wrong. Better a failed cron run in the logs than half a database less.
  --
  -- BOTH bounds have to hold, not the more generous of the two: the proportion
  -- alone would be without effect on a small instance (25 % of 65 is 16), the
  -- absolute number alone on a large one. A first run with a backlog may break
  -- the limit — then a human should look and deliberately raise it, rather than
  -- the night quietly taking care of it.
  SELECT count(*) INTO v_total FROM public.profiles;
  IF v_n > p_max_delete OR v_n * 100 > v_total * p_max_percent THEN
    RAISE EXCEPTION
      'purge_dormant_accounts: % von % Konten getroffen (max % bzw. % %%) — Abbruch',
      v_n, v_total, p_max_delete, p_max_percent;
  END IF;

  IF p_dry_run THEN
    RETURN v_n;
  END IF;

  -- None of these tables hangs on `profiles` via CASCADE — whoever deletes only
  -- the profile leaves them standing. `device_tokens` hangs on `auth.users`
  -- (00001:129) and would disappear only with the last row below; explicit is
  -- better, because the order is then not part of the correctness.
  DELETE FROM public.device_tokens        WHERE user_id = ANY(v_ids);
  DELETE FROM public.chat_member_prekeys  WHERE user_id = ANY(v_ids);
  DELETE FROM public.chat_mute_prefs      WHERE user_id = ANY(v_ids);
  DELETE FROM public.pending_chat_members WHERE user_id = ANY(v_ids);
  DELETE FROM public.recovery_credentials WHERE user_id = ANY(v_ids);

  DELETE FROM public.profiles WHERE id = ANY(v_ids);
  DELETE FROM auth.users      WHERE id = ANY(v_ids);

  -- What is logged is the NUMBER, not who. Writing the names of the accounts
  -- just deleted into the audit would mean keeping them precisely there.
  INSERT INTO public.admin_audit (operator_id, operator_label, action, target_type, detail)
  VALUES (NULL, 'system (cron)', 'purge_dormant_accounts', 'profiles',
          jsonb_build_object('deleted', v_n, 'age', p_age::text, 'cutoff', v_cutoff));

  RETURN v_n;
END;
$$;

COMMENT ON FUNCTION public.purge_dormant_accounts(interval, boolean, integer, integer) IS
  'Löscht Konten ohne jede Nutzungsspur, die älter als p_age sind (Default 3 Monate). '
  'p_dry_run => nur zählen (die Reißleine greift dabei trotzdem, damit ein '
  'Trockenlauf das Problem zeigt). Bricht ab, wenn der Lauf p_max_delete Konten '
  'oder p_max_percent Prozent der Instanz überschreitet.';

REVOKE ALL ON FUNCTION public.purge_dormant_accounts(interval, boolean, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.purge_dormant_accounts(interval, boolean, integer, integer) TO service_role;

-- ---------------------------------------------------------------------------
-- The schedule. pg_cron is in shared_preload_libraries (the Supabase default)
-- but is not enabled everywhere — if it is missing, the function is still there
-- and can be called by hand or via a host cron. No reason to let the migration
-- fail.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
    EXECUTE 'CREATE EXTENSION IF NOT EXISTS pg_cron';
    -- At night, at an odd minute, so the run does not coincide with everything
    -- else that starts on the hour.
    PERFORM cron.unschedule('purge-dormant-accounts')
      WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'purge-dormant-accounts');
    PERFORM cron.schedule('purge-dormant-accounts', '17 4 * * *',
                          'SELECT public.purge_dormant_accounts()');
    RAISE NOTICE 'purge-dormant-accounts: täglich 04:17 UTC eingeplant';
  ELSE
    RAISE NOTICE 'pg_cron nicht verfügbar — purge_dormant_accounts() muss extern gerufen werden';
  END IF;
END $$;
