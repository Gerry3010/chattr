-- SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
-- SPDX-License-Identifier: AGPL-3.0-or-later

-- ============================================================================
-- 00076: which app version is actually running out there?
-- ----------------------------------------------------------------------------
-- Several decisions in the backend have the same shape: "that may only go once the
-- old clients are gone". Two are currently open:
--
--   * **00075** (avatar store private). A client before 1.22.0 builds the image
--     address with `getPublicUrl`; against a private bucket that answers with 400,
--     and that device shows initials instead of pictures everywhere.
--   * **00063** (private realtime channel). The old public channel is still served
--     IN PARALLEL today, so older installations do not go deaf. Every message
--     therefore goes out twice.
--
-- Both wait on the same answer — and it was not available until now.
-- `device_tokens` knows WHICH device is reachable, but not WHAT runs on it. The only
-- approximation was `local_render` (00065), and that is blunt: it says "at least the
-- version that can do push without plaintext" and nothing about anything after.
-- "Is the fleet through?" thereby became a guess — and a wrong guess takes real
-- users' pictures or notifications away.
--
-- This migration turns that into a query. Purely additive: one column the client
-- writes along with every token renewal (where `local_render` already stands), and
-- an evaluation over it.
--
-- **What that costs in data, named honestly.** The row already knows `user_id`,
-- `platform` and `updated_at`; the version number is added. It is not personal data
-- and is not disadvantageous to the person concerned either — but it does make a
-- device somewhat more recognisable, which is why it stands here and not silently in
-- the code. The version number only, no device model, no OS level: what is stored is
-- what the decision needs.
--
-- NULL means "has never said" — so a client from before this line. For a rollout
-- gate that is the MOST IMPORTANT group: unknown is old in case of doubt. The
-- evaluation below therefore reports it separately rather than leaving it out.
-- ============================================================================

ALTER TABLE public.device_tokens
  ADD COLUMN IF NOT EXISTS app_version TEXT;

COMMENT ON COLUMN public.device_tokens.app_version IS
  'Version der App auf diesem Gerät ("1.23.1"), vom Client bei jeder '
  'Token-Erneuerung geschrieben. Dient dem Rollout-Gate: „läuft irgendwo noch '
  'ein Client vor X?" NULL = ein Build von vor 00076, also im Zweifel alt.';

-- ============================================================================
-- Evaluation: one row per platform and version
-- ============================================================================
-- `last_seen` is the part that makes the number usable: a token that has not
-- been renewed for months usually belongs to an uninstalled app and must not
-- block a gate forever. But the decision as to when a device counts as "gone"
-- belongs to the human who makes it — so the function supplies the date and
-- does not truncate by itself.

CREATE OR REPLACE FUNCTION public.fleet_app_versions()
RETURNS TABLE(
  platform TEXT,
  app_version TEXT,
  devices BIGINT,
  users BIGINT,
  last_seen TIMESTAMPTZ
)
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE sql
AS $$
  SELECT
    dt.platform,
    dt.app_version,
    COUNT(*)                   AS devices,
    COUNT(DISTINCT dt.user_id) AS users,
    MAX(dt.updated_at)         AS last_seen
  FROM public.device_tokens dt
  GROUP BY dt.platform, dt.app_version
  -- NULL (unknown/old) first: that is the group holding a gate up.
  ORDER BY dt.platform, dt.app_version NULLS FIRST;
$$;

COMMENT ON FUNCTION public.fleet_app_versions IS
  'Geräte je Plattform und App-Version, mit letzter Token-Erneuerung. Für '
  'Rollout-Gates ("ist die Flotte über 1.22?"). app_version NULL = Build von '
  'vor 00076. Nur service_role.';

-- This is operational knowledge about other people's devices — no signed-in
-- user has any business seeing it.
REVOKE EXECUTE ON FUNCTION public.fleet_app_versions() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.fleet_app_versions() FROM anon;
REVOKE EXECUTE ON FUNCTION public.fleet_app_versions() FROM authenticated;
GRANT EXECUTE ON FUNCTION public.fleet_app_versions() TO service_role;
