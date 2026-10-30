-- SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
-- SPDX-License-Identifier: AGPL-3.0-or-later

-- ============================================================================
-- 00066: media-kind split reads the right column + watchlist patterns are
--        validated on write
-- ----------------------------------------------------------------------------
-- Two unrelated fixes to the content-blind admin surface, both of the same
-- shape: something the panel promised was never actually wired to reality.
--
-- Part 1 — the media kind split read a column no client can write.
-- Part 2 — a malformed watchlist regex was accepted on save and only exploded
--          later, on every Signals query. See each section below.
-- ----------------------------------------------------------------------------
-- 00058 shipped `metrics_media_by_kind()` reading `storage.objects.metadata
-- ->>'x-media-kind'`, and the client hook that was supposed to fill it was
-- deferred. Now that the hook exists (MediaRepository._fileOptions) the wrong
-- column is visible: storage.objects has TWO metadata columns and they belong
-- to different owners.
--
--   metadata       — system-owned, written by storage-api itself
--                    (size, mimetype, eTag, cacheControl, httpStatusCode).
--                    A client cannot put anything here.
--   user_metadata  — caller-supplied. The Supabase client sends it as a
--                    multipart `metadata` field on upload; storage-api lands it
--                    here. This is where `x-media-kind` actually arrives.
--
-- So the old expression could only ever return 'unknown', which is exactly what
-- the dashboard's media panel showed. Read `user_metadata` first and keep the
-- old branch as a fallback: harmless, and it means a future storage-api that
-- merges the two does not silently blank the chart again.
--
-- Content-blindness is unchanged. The tag is a coarse category the sender's
-- client attaches (image/video/audio/other) — no filename, no mime subtype, no
-- content. Blobs uploaded before the client hook have no tag at all and stay
-- 'unknown' forever; they age out with normal media retention (00056), so the
-- split becomes complete on its own rather than through a backfill that would
-- have to guess.
--
-- `total_bytes` deliberately stays on `metadata->>'size'`: the byte count is
-- storage-api's own bookkeeping and must not be taken from a client-supplied
-- value.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.metrics_media_by_kind()
RETURNS TABLE(kind text, blob_count bigint, total_bytes bigint)
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE sql
STABLE
AS $$
  SELECT COALESCE(
           NULLIF(o.user_metadata->>'x-media-kind', ''),
           NULLIF(o.metadata->>'x-media-kind', ''),
           'unknown'
         ) AS kind,
         COUNT(*)::bigint,
         COALESCE(SUM((o.metadata->>'size')::bigint), 0)::bigint
  FROM storage.objects o
  WHERE o.bucket_id = 'media'
  GROUP BY 1
  ORDER BY 1;
$$;

-- Same posture as 00058: readable only by the admin-stats edge function.
REVOKE EXECUTE ON FUNCTION public.metrics_media_by_kind() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.metrics_media_by_kind() FROM anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.metrics_media_by_kind() TO service_role;

-- ============================================================================
-- Watchlist patterns are validated at the door
-- ----------------------------------------------------------------------------
-- `moderation_terms.pattern` goes straight into `~*` inside abuse_signals().
-- Postgres does not compile a regex until it runs, so ONE malformed pattern —
-- a stray `(`, a dangling `[` — does not fail on save. It fails later, on
-- every call, taking down the entire Signals tab with "invalid regular
-- expression" and no hint which of N terms caused it. Neither write path
-- (moderation_term_add, moderation_list_import) checked.
--
-- That was survivable while the lists were nine profanity words typed by hand.
-- It stops being survivable the moment someone imports a hundred-term file.
--
-- Validating at the door is enough: moderation_terms is RLS deny-all, so these
-- two SECURITY DEFINER functions are the only way a row gets in. abuse_signals
-- itself stays untouched — filtering there would mean a plpgsql subtransaction
-- per term per profile on the hot path, to guard against rows that can no
-- longer exist.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.moderation_pattern_valid(p_pattern TEXT)
RETURNS BOOLEAN
SET search_path = public, pg_temp
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
  -- Compile it by using it. The probe string is irrelevant — a match or a
  -- non-match both prove the pattern is well-formed.
  PERFORM 'chattr-pattern-probe' ~* p_pattern;
  RETURN TRUE;
EXCEPTION WHEN OTHERS THEN
  RETURN FALSE;
END;
$$;

CREATE OR REPLACE FUNCTION public.moderation_term_add(
  p_list_id UUID, p_pattern TEXT, p_category TEXT DEFAULT 'other', p_by UUID DEFAULT NULL)
RETURNS UUID SECURITY DEFINER SET search_path = public, pg_temp LANGUAGE plpgsql AS $$
DECLARE v_id UUID;
BEGIN
  IF COALESCE(p_pattern, '') = '' THEN
    RAISE EXCEPTION 'empty pattern' USING ERRCODE = '22023';
  END IF;
  IF NOT public.moderation_pattern_valid(p_pattern) THEN
    RAISE EXCEPTION 'invalid regular expression: %', p_pattern USING ERRCODE = '2201B';
  END IF;
  INSERT INTO public.moderation_terms(list_id, pattern, category)
  VALUES (p_list_id, p_pattern, COALESCE(p_category, 'other'))
  RETURNING id INTO v_id;
  PERFORM public.admin_write_audit(p_by, 'term_add', 'term', v_id::text,
                                   jsonb_build_object('list_id', p_list_id, 'pattern', p_pattern));
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.moderation_list_import(p_payload JSONB, p_by UUID DEFAULT NULL)
RETURNS UUID SECURITY DEFINER SET search_path = public, pg_temp LANGUAGE plpgsql AS $$
DECLARE v_list UUID; v_count INT; v_bad TEXT;
BEGIN
  -- Reject the whole file rather than importing it half-scanned: a list that
  -- silently dropped three of its terms looks exactly like a list that is
  -- working. Naming the offender is the point — that is what the operator
  -- could not get out of the runtime error.
  SELECT e->>'pattern' INTO v_bad
  FROM jsonb_array_elements(COALESCE(p_payload->'terms', '[]'::jsonb)) e
  WHERE COALESCE(e->>'pattern', '') <> ''
    AND NOT public.moderation_pattern_valid(e->>'pattern')
  LIMIT 1;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'invalid regular expression in import: %', v_bad USING ERRCODE = '2201B';
  END IF;

  INSERT INTO public.moderation_lists(name, description, source)
  VALUES (COALESCE(NULLIF(p_payload->>'name', ''), 'Imported'),
          p_payload->>'description',
          CASE WHEN p_payload->>'source' = 'preset' THEN 'preset' ELSE 'custom' END)
  RETURNING id INTO v_list;

  INSERT INTO public.moderation_terms(list_id, pattern, category)
  SELECT v_list, e->>'pattern', COALESCE(NULLIF(e->>'category', ''), 'other')
  FROM jsonb_array_elements(COALESCE(p_payload->'terms', '[]'::jsonb)) e
  WHERE COALESCE(e->>'pattern', '') <> '';
  GET DIAGNOSTICS v_count = ROW_COUNT;

  PERFORM public.admin_write_audit(p_by, 'list_import', 'list', v_list::text,
                                   jsonb_build_object('name', p_payload->>'name', 'terms', v_count));
  RETURN v_list;
END;
$$;

-- Same lock-down as every other admin RPC (00060/00061): service_role only.
DO $$
DECLARE fn text;
BEGIN
  FOREACH fn IN ARRAY ARRAY[
    'moderation_pattern_valid(text)',
    'moderation_term_add(uuid,text,text,uuid)',
    'moderation_list_import(jsonb,uuid)'
  ] LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION public.%s FROM PUBLIC', fn);
    EXECUTE format('REVOKE EXECUTE ON FUNCTION public.%s FROM anon, authenticated', fn);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO service_role', fn);
  END LOOP;
END $$;
