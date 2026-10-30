-- SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
-- SPDX-License-Identifier: AGPL-3.0-or-later

-- ============================================================================
-- 00059: Coarse activity signal for DAU/WAU/MAU + retention
-- ----------------------------------------------------------------------------
-- The schema had no "active" signal (only signup time). For DAU/WAU/MAU we add
-- ONE deliberately coarse field: profiles.last_active_date — a DATE (no time of
-- day), updated at most once per user per day. That granularity is the privacy
-- floor: it can't reconstruct a per-user activity timeline finer than "was
-- active on day X", and only the LATEST such day is kept.
--
-- touch_last_active() is called by the client on foreground; the aggregate RPCs
-- are service_role-only (admin-stats edge fn), mirroring 00058.
-- ============================================================================

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS last_active_date DATE;

COMMENT ON COLUMN public.profiles.last_active_date IS
  'Coarse activity signal: the most recent calendar day this user opened the app (day granularity only, no time). Used for DAU/WAU/MAU. Set by touch_last_active().';

-- Partial index to keep the rolling-window counts cheap.
CREATE INDEX IF NOT EXISTS idx_profiles_last_active
  ON public.profiles (last_active_date)
  WHERE last_active_date IS NOT NULL;

-- ----------------------------------------------------------------------------
-- touch_last_active — idempotent, own-row only, ≤ 1 write/user/day.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.touch_last_active()
RETURNS VOID
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE sql
AS $$
  UPDATE public.profiles
  SET last_active_date = CURRENT_DATE
  WHERE id = auth.uid()
    AND (last_active_date IS DISTINCT FROM CURRENT_DATE);
$$;

COMMENT ON FUNCTION public.touch_last_active IS
  'Marks the caller active today (day-granular, idempotent). Callable by authenticated only.';

REVOKE EXECUTE ON FUNCTION public.touch_last_active() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.touch_last_active() TO authenticated;

-- ----------------------------------------------------------------------------
-- metrics_active_users — point-in-time DAU / WAU / MAU. last_active_date holds
-- only the MOST RECENT active day per user, so these rolling windows are exact
-- for "active within N days", which is the standard DAU/WAU/MAU definition.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.metrics_active_users()
RETURNS TABLE(metric text, value bigint)
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE sql
STABLE
AS $$
  SELECT 'dau', COUNT(*)::bigint FROM public.profiles WHERE last_active_date = CURRENT_DATE
  UNION ALL
  SELECT 'wau', COUNT(*)::bigint FROM public.profiles WHERE last_active_date >= CURRENT_DATE - 6
  UNION ALL
  SELECT 'mau', COUNT(*)::bigint FROM public.profiles WHERE last_active_date >= CURRENT_DATE - 29
  UNION ALL
  SELECT 'users_total', COUNT(*)::bigint FROM public.profiles;
$$;

-- ----------------------------------------------------------------------------
-- metrics_retention — signup-week cohorts × still active in the last 30 days.
-- Coarse (uses only the latest active day) but enough for a retention read.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.metrics_retention()
RETURNS TABLE(cohort_week timestamptz, cohort_size bigint, retained bigint)
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE sql
STABLE
AS $$
  SELECT date_trunc('week', p.created_at) AS cohort_week,
         COUNT(*)::bigint AS cohort_size,
         COUNT(*) FILTER (
           WHERE p.last_active_date >= CURRENT_DATE - 29
         )::bigint AS retained
  FROM public.profiles p
  WHERE p.created_at IS NOT NULL
  GROUP BY 1
  ORDER BY 1;
$$;

-- Lock the aggregate readers to service_role only.
REVOKE EXECUTE ON FUNCTION public.metrics_active_users() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.metrics_active_users() TO service_role;
REVOKE EXECUTE ON FUNCTION public.metrics_retention() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.metrics_retention() TO service_role;
