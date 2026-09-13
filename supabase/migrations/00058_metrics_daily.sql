-- SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
-- SPDX-License-Identifier: AGPL-3.0-or-later

-- ============================================================================
-- 00058: Admin metrics — snapshot counter + privacy-safe aggregate RPCs
-- ----------------------------------------------------------------------------
-- Backend for the internal admin dashboard. Two shapes of metric:
--
--   1. EPHEMERAL volume (messages) — the source rows self-prune (read+7d /
--      unreceived+30d / self-destruct TTL), so a retrospective COUNT is
--      impossible. We snapshot the count at INSERT time into an append-only
--      `metrics_daily` table. The counter is CONTENT-BLIND: it records only a
--      day + a running count, never a user id, sender, recipient, or content —
--      it can never become a surveillance log.
--
--   2. DURABLE aggregates (signups, chats, blocks, reactions, …) — those tables
--      are not reaped, so they are aggregated live, bucketed by day/week/month.
--
-- Everything here is METADATA-ONLY. Message content is E2E-encrypted and
-- `encrypted_content` is blanked on delivery anyway; nothing in this file reads,
-- decrypts, or exposes any message body. All RPCs are SECURITY DEFINER and
-- locked to service_role (called only by the admin-stats edge function) — the
-- REVOKE/GRANT pattern mirrors 00045.
--
-- Fan-out note: `messages` PK is (id, recipient_id) → one logical message = N
-- rows. The client inserts all copies in ONE batch statement
-- (messages_repository.dart `insert(mapRows)`), so a STATEMENT-level trigger
-- with a transition table can COUNT(DISTINCT id) to count logical messages once.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. metrics_daily — append-only, aggregate-only. No user linkage by design.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.metrics_daily (
  day    DATE   NOT NULL,
  metric TEXT   NOT NULL,
  value  BIGINT NOT NULL DEFAULT 0,
  PRIMARY KEY (day, metric)
);

COMMENT ON TABLE public.metrics_daily IS
  'Append-only aggregate counters (day + metric + running count). No user/sender/content — cannot become a surveillance log. Snapshots ephemeral volume that self-prunes from source tables.';

-- RLS on with NO policies → denies anon/authenticated entirely. Only the
-- SECURITY DEFINER trigger writes it, and service_role reads it.
ALTER TABLE public.metrics_daily ENABLE ROW LEVEL SECURITY;

-- ----------------------------------------------------------------------------
-- 2. Message volume counter — statement-level AFTER INSERT with a transition
--    table. Counts distinct logical USER messages per calendar day. SECURITY
--    DEFINER so it can write metrics_daily past that table's deny-all RLS.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bump_message_metric()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO public.metrics_daily (day, metric, value)
  SELECT (n.created_at)::date, 'messages_sent', COUNT(DISTINCT n.id)
  FROM new_rows n
  WHERE n.message_type = 'user'
    AND n.created_at IS NOT NULL
  GROUP BY (n.created_at)::date
  ON CONFLICT (day, metric)
    DO UPDATE SET value = public.metrics_daily.value + EXCLUDED.value;
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS bump_message_metric_trigger ON public.messages;
CREATE TRIGGER bump_message_metric_trigger
  AFTER INSERT ON public.messages
  REFERENCING NEW TABLE AS new_rows
  FOR EACH STATEMENT
  EXECUTE FUNCTION public.bump_message_metric();

REVOKE EXECUTE ON FUNCTION public.bump_message_metric() FROM PUBLIC, anon, authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 3. Reader for the snapshot table (message/media volume time series).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.metrics_daily_series(p_metrics text[] DEFAULT NULL)
RETURNS TABLE(day date, metric text, value bigint)
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE sql
STABLE
AS $$
  SELECT m.day, m.metric, m.value
  FROM public.metrics_daily m
  WHERE p_metrics IS NULL OR m.metric = ANY(p_metrics)
  ORDER BY m.day, m.metric;
$$;

-- ----------------------------------------------------------------------------
-- 4. Durable aggregate RPCs — bucketed live over non-reaped tables.
--    `p_bucket` is validated to a fixed allowlist and passed to date_trunc.
-- ----------------------------------------------------------------------------

-- New signups per bucket.
CREATE OR REPLACE FUNCTION public.metrics_signups(p_bucket text DEFAULT 'day')
RETURNS TABLE(bucket timestamptz, value bigint)
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
  IF p_bucket NOT IN ('day', 'week', 'month') THEN
    RAISE EXCEPTION 'invalid bucket %', p_bucket USING ERRCODE = '22023';
  END IF;
  RETURN QUERY
  SELECT date_trunc(p_bucket, p.created_at) AS bucket, COUNT(*)::bigint
  FROM public.profiles p
  WHERE p.created_at IS NOT NULL
  GROUP BY 1
  ORDER BY 1;
END;
$$;

-- New chats per bucket, split by group vs direct.
CREATE OR REPLACE FUNCTION public.metrics_chats(p_bucket text DEFAULT 'day')
RETURNS TABLE(bucket timestamptz, kind text, value bigint)
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
  IF p_bucket NOT IN ('day', 'week', 'month') THEN
    RAISE EXCEPTION 'invalid bucket %', p_bucket USING ERRCODE = '22023';
  END IF;
  RETURN QUERY
  SELECT date_trunc(p_bucket, c.created_at) AS bucket,
         CASE WHEN c.is_group THEN 'group' ELSE 'direct' END AS kind,
         COUNT(*)::bigint
  FROM public.chats c
  WHERE c.created_at IS NOT NULL
  GROUP BY 1, 2
  ORDER BY 1, 2;
END;
$$;

-- Blocks created per bucket.
CREATE OR REPLACE FUNCTION public.metrics_blocks(p_bucket text DEFAULT 'day')
RETURNS TABLE(bucket timestamptz, value bigint)
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
  IF p_bucket NOT IN ('day', 'week', 'month') THEN
    RAISE EXCEPTION 'invalid bucket %', p_bucket USING ERRCODE = '22023';
  END IF;
  RETURN QUERY
  SELECT date_trunc(p_bucket, b.created_at) AS bucket, COUNT(*)::bigint
  FROM public.blocked_users b
  GROUP BY 1
  ORDER BY 1;
END;
$$;

-- Reactions per bucket.
CREATE OR REPLACE FUNCTION public.metrics_reactions(p_bucket text DEFAULT 'day')
RETURNS TABLE(bucket timestamptz, value bigint)
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
  IF p_bucket NOT IN ('day', 'week', 'month') THEN
    RAISE EXCEPTION 'invalid bucket %', p_bucket USING ERRCODE = '22023';
  END IF;
  RETURN QUERY
  SELECT date_trunc(p_bucket, r.created_at) AS bucket, COUNT(*)::bigint
  FROM public.message_reactions r
  GROUP BY 1
  ORDER BY 1;
END;
$$;

-- Pending join requests per bucket.
CREATE OR REPLACE FUNCTION public.metrics_pending_requests(p_bucket text DEFAULT 'day')
RETURNS TABLE(bucket timestamptz, value bigint)
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
  IF p_bucket NOT IN ('day', 'week', 'month') THEN
    RAISE EXCEPTION 'invalid bucket %', p_bucket USING ERRCODE = '22023';
  END IF;
  RETURN QUERY
  SELECT date_trunc(p_bucket, pcm.created_at) AS bucket, COUNT(*)::bigint
  FROM public.pending_chat_members pcm
  GROUP BY 1
  ORDER BY 1;
END;
$$;

-- Current device/platform mix (point-in-time snapshot).
CREATE OR REPLACE FUNCTION public.metrics_platform_mix()
RETURNS TABLE(platform text, value bigint)
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE sql
STABLE
AS $$
  SELECT dt.platform, COUNT(DISTINCT dt.user_id)::bigint
  FROM public.device_tokens dt
  GROUP BY dt.platform
  ORDER BY dt.platform;
$$;

-- Trust-layer adoption (point-in-time): identity keys registered + prekey pools.
CREATE OR REPLACE FUNCTION public.metrics_trust_adoption()
RETURNS TABLE(metric text, value bigint)
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE sql
STABLE
AS $$
  SELECT 'profiles_total', COUNT(*)::bigint FROM public.profiles
  UNION ALL
  SELECT 'profiles_with_identity_key',
         COUNT(*)::bigint FROM public.profiles WHERE identity_public_key IS NOT NULL
  UNION ALL
  SELECT 'members_total', COUNT(*)::bigint FROM public.chat_members
  UNION ALL
  SELECT 'members_with_prekeys',
         COUNT(DISTINCT (cmp.chat_id, cmp.user_id))::bigint
         FROM public.chat_member_prekeys cmp
         WHERE cmp.consumed_at IS NULL;
$$;

-- ----------------------------------------------------------------------------
-- 5. Media snapshot RPCs — read the private `media` storage bucket.
--    storage.objects is NOT exposed via PostgREST (see 00034), so access is via
--    SECURITY DEFINER only. GOTCHA (documented in 00055/00056): `chats` has a
--    `name` column, so an unqualified `name` in any subquery joining chats binds
--    to chats.name. We alias storage.objects AS `o` and always use `o.name`.
--    Strictly bucket_id='media' → the public avatars/group-avatars buckets are
--    excluded. Byte size = o.metadata->>'size' (ciphertext bytes ≈ original).
-- ----------------------------------------------------------------------------

-- Totals: how many blobs are on the server + how much storage they use.
CREATE OR REPLACE FUNCTION public.metrics_media_totals()
RETURNS TABLE(blob_count bigint, total_bytes bigint)
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE sql
STABLE
AS $$
  SELECT COUNT(*)::bigint,
         COALESCE(SUM((o.metadata->>'size')::bigint), 0)::bigint
  FROM storage.objects o
  WHERE o.bucket_id = 'media';
$$;

-- "Not yet fetched": blobs where at least one recipient has NOT confirmed a
-- download (media_downloads, 00056). This is the negation of the reaper's
-- "downloaded-by-all" pass — the same signal media retention v3 keys off.
CREATE OR REPLACE FUNCTION public.metrics_media_pending()
RETURNS TABLE(blob_count bigint, total_bytes bigint)
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE sql
STABLE
AS $$
  SELECT COUNT(*)::bigint,
         COALESCE(SUM((o.metadata->>'size')::bigint), 0)::bigint
  FROM storage.objects o
  WHERE o.bucket_id = 'media'
    AND split_part(o.name, '/', 2) ~
        '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'
    AND EXISTS (
      -- at least one real recipient copy exists (not just the sender's own)
      SELECT 1 FROM public.messages m
      WHERE m.id = split_part(o.name, '/', 2)::uuid
        AND m.recipient_id IS DISTINCT FROM m.sender_id
    )
    AND EXISTS (
      -- and at least one such recipient has NOT confirmed a download
      SELECT 1 FROM public.messages m
      WHERE m.id = split_part(o.name, '/', 2)::uuid
        AND m.recipient_id IS DISTINCT FROM m.sender_id
        AND NOT EXISTS (
          SELECT 1 FROM public.media_downloads d
          WHERE d.message_id = m.id
            AND d.recipient_id = m.recipient_id
        )
    );
$$;

-- Storage hygiene: blobs due for reaping (unreferenced / past hard cap /
-- downloaded-by-all). Reuses the shipped reaper list (00056).
CREATE OR REPLACE FUNCTION public.metrics_media_unreferenced()
RETURNS TABLE(blob_count bigint, total_bytes bigint)
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE sql
STABLE
AS $$
  SELECT COUNT(*)::bigint,
         COALESCE(SUM((o.metadata->>'size')::bigint), 0)::bigint
  FROM storage.objects o
  WHERE o.bucket_id = 'media'
    AND o.name IN (SELECT r.name FROM public.media_objects_to_reap() r);
$$;

-- Split by coarse media kind (image/video/audio/other). Kind is a deliberate,
-- content-free category tag the client sets at upload
-- (metadata->>'x-media-kind'); blobs without it fall into 'unknown'.
CREATE OR REPLACE FUNCTION public.metrics_media_by_kind()
RETURNS TABLE(kind text, blob_count bigint, total_bytes bigint)
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE sql
STABLE
AS $$
  SELECT COALESCE(NULLIF(o.metadata->>'x-media-kind', ''), 'unknown') AS kind,
         COUNT(*)::bigint,
         COALESCE(SUM((o.metadata->>'size')::bigint), 0)::bigint
  FROM storage.objects o
  WHERE o.bucket_id = 'media'
  GROUP BY 1
  ORDER BY 1;
$$;

-- ----------------------------------------------------------------------------
-- 6. Lock every reader RPC to service_role only (admin-stats edge fn).
-- ----------------------------------------------------------------------------
DO $$
DECLARE fn text;
BEGIN
  FOREACH fn IN ARRAY ARRAY[
    'metrics_daily_series(text[])',
    'metrics_signups(text)',
    'metrics_chats(text)',
    'metrics_blocks(text)',
    'metrics_reactions(text)',
    'metrics_pending_requests(text)',
    'metrics_platform_mix()',
    'metrics_trust_adoption()',
    'metrics_media_totals()',
    'metrics_media_pending()',
    'metrics_media_unreferenced()',
    'metrics_media_by_kind()'
  ]
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION public.%s FROM PUBLIC, anon, authenticated', fn);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO service_role', fn);
  END LOOP;
END;
$$;
