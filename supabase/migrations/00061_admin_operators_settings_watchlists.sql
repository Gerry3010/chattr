-- SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
-- SPDX-License-Identifier: AGPL-3.0-or-later

-- ============================================================================
-- 00061: Operator accounts, admin settings, multi-watchlists, audit log
-- ----------------------------------------------------------------------------
-- Extends the content-blind admin surface (00058-00060):
--
--  * admin_operators — the FIRST notion of a distinct operator identity. Until
--    now the panel authenticated with one shared ADMIN_STATS_SECRET (no "who").
--    Backwards-compatible: 0 operators → legacy single-operator mode (the edge
--    fn's shared secret alone is enough). Add one → login required thereafter.
--    Passwords are bcrypt (pgcrypto crypt/gen_salt), never plaintext.
--  * admin_settings — kv config so the previously-hardcoded moderation params
--    (content gate cap, false-flag threshold/decay) are tunable from the panel.
--  * moderation_lists — multiple named watchlists (custom + imported presets),
--    each enable/disable-able; moderation_terms now belongs to a list. Only
--    ENABLED lists feed abuse_signals. Import/export via JSON.
--  * admin_audit — every moderation action (ban/unban/resolve/restore/term/…)
--    is attributed to an operator + timestamped. Nothing was logged before.
--
-- All new tables are RLS deny-all → reachable only through SECURITY DEFINER
-- RPCs granted to service_role (the admin-stats edge fn). Same posture as
-- moderation_terms in 00060: no table grants to anon/authenticated.
-- ============================================================================

-- pgcrypto for password hashing (Supabase ships it in the extensions schema).
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

-- ----------------------------------------------------------------------------
-- 1. Operator accounts
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.admin_operators (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  username      TEXT NOT NULL UNIQUE,            -- stored lower-cased
  password_hash TEXT NOT NULL,                   -- bcrypt (crypt/gen_salt('bf'))
  role          TEXT NOT NULL DEFAULT 'moderator'
                  CHECK (role IN ('admin', 'moderator')),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  disabled_at   TIMESTAMPTZ,
  last_login_at TIMESTAMPTZ
);
ALTER TABLE public.admin_operators ENABLE ROW LEVEL SECURITY;  -- deny-all

-- ----------------------------------------------------------------------------
-- 2. Settings (kv) — seed the values that were hardcoded in 00060.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.admin_settings (
  key        TEXT PRIMARY KEY,
  value      JSONB NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.admin_settings ENABLE ROW LEVEL SECURITY;   -- deny-all

INSERT INTO public.admin_settings(key, value) VALUES
  ('false_flag_threshold',    '3'::jsonb),
  ('false_flag_decay_months', '6'::jsonb),
  ('content_gate_cap',        '3'::jsonb)
ON CONFLICT (key) DO NOTHING;

-- ----------------------------------------------------------------------------
-- 3. Audit log
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.admin_audit (
  id             BIGSERIAL PRIMARY KEY,
  operator_id    UUID REFERENCES public.admin_operators(id) ON DELETE SET NULL,
  operator_label TEXT NOT NULL,                  -- snapshot; survives operator deletion
  action         TEXT NOT NULL,
  target_type    TEXT,
  target_id      TEXT,
  detail         JSONB,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.admin_audit ENABLE ROW LEVEL SECURITY;      -- deny-all
CREATE INDEX IF NOT EXISTS idx_admin_audit_created ON public.admin_audit (id DESC);

-- Internal audit writer (owned by definer; callable only from other SECDEF fns).
CREATE OR REPLACE FUNCTION public.admin_write_audit(
  p_by UUID, p_action TEXT, p_target_type TEXT DEFAULT NULL,
  p_target_id TEXT DEFAULT NULL, p_detail JSONB DEFAULT NULL)
RETURNS VOID SECURITY DEFINER SET search_path = public, pg_temp LANGUAGE plpgsql AS $$
DECLARE v_label TEXT;
BEGIN
  IF p_by IS NOT NULL THEN
    SELECT username INTO v_label FROM public.admin_operators WHERE id = p_by;
  END IF;
  INSERT INTO public.admin_audit(operator_id, operator_label, action, target_type, target_id, detail)
  VALUES (p_by, COALESCE(v_label, CASE WHEN p_by IS NULL THEN '(bootstrap)' ELSE '(unknown)' END),
          p_action, p_target_type, p_target_id, p_detail);
END;
$$;

-- Internal settings reader (int with fallback).
CREATE OR REPLACE FUNCTION public.admin_setting_int(p_key TEXT, p_default INT)
RETURNS INT SECURITY DEFINER SET search_path = public, pg_temp LANGUAGE sql STABLE AS $$
  SELECT COALESCE((SELECT (value #>> '{}')::int FROM public.admin_settings WHERE key = p_key), p_default);
$$;

-- ----------------------------------------------------------------------------
-- 4. Multi-watchlists: moderation_lists + moderation_terms.list_id
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.moderation_lists (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name        TEXT NOT NULL,
  description TEXT,
  source      TEXT NOT NULL DEFAULT 'custom' CHECK (source IN ('custom', 'preset')),
  enabled     BOOLEAN NOT NULL DEFAULT true,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.moderation_lists ENABLE ROW LEVEL SECURITY; -- deny-all

-- Default list (fixed id) so the backfill is deterministic.
INSERT INTO public.moderation_lists(id, name, description, source)
VALUES ('11111111-1111-4111-8111-111111111111'::uuid, 'Custom', 'Default watchlist', 'custom')
ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.moderation_terms
  ADD COLUMN IF NOT EXISTS list_id UUID REFERENCES public.moderation_lists(id) ON DELETE CASCADE;
UPDATE public.moderation_terms
  SET list_id = '11111111-1111-4111-8111-111111111111'::uuid WHERE list_id IS NULL;
CREATE INDEX IF NOT EXISTS idx_moderation_terms_list ON public.moderation_terms (list_id);

-- ----------------------------------------------------------------------------
-- 5. Operator RPCs (service_role only, except where noted)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_operator_count()
RETURNS BIGINT SECURITY DEFINER SET search_path = public, pg_temp LANGUAGE sql STABLE AS $$
  SELECT COUNT(*) FROM public.admin_operators WHERE disabled_at IS NULL;
$$;

CREATE OR REPLACE FUNCTION public.admin_login(p_username TEXT, p_password TEXT)
RETURNS TABLE(operator_id UUID, username TEXT, role TEXT)
SECURITY DEFINER SET search_path = public, extensions, pg_temp LANGUAGE plpgsql AS $$
DECLARE v_id UUID; v_user TEXT; v_role TEXT;
BEGIN
  SELECT o.id, o.username, o.role INTO v_id, v_user, v_role
  FROM public.admin_operators o
  WHERE o.username = lower(p_username)
    AND o.disabled_at IS NULL
    AND o.password_hash = crypt(p_password, o.password_hash);
  IF v_id IS NULL THEN RETURN; END IF;                 -- empty = auth failed
  UPDATE public.admin_operators SET last_login_at = now() WHERE id = v_id;
  PERFORM public.admin_write_audit(v_id, 'login', 'operator', v_id::text, NULL);
  RETURN QUERY SELECT v_id, v_user, v_role;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_operators_list()
RETURNS TABLE(id UUID, username TEXT, role TEXT, disabled_at TIMESTAMPTZ,
              last_login_at TIMESTAMPTZ, created_at TIMESTAMPTZ)
SECURITY DEFINER SET search_path = public, pg_temp LANGUAGE sql STABLE AS $$
  SELECT id, username, role, disabled_at, last_login_at, created_at
  FROM public.admin_operators ORDER BY created_at;
$$;

CREATE OR REPLACE FUNCTION public.admin_operator_add(
  p_username TEXT, p_password TEXT, p_role TEXT DEFAULT 'moderator', p_by UUID DEFAULT NULL)
RETURNS UUID SECURITY DEFINER SET search_path = public, extensions, pg_temp LANGUAGE plpgsql AS $$
DECLARE v_id UUID;
BEGIN
  IF p_role NOT IN ('admin', 'moderator') THEN
    RAISE EXCEPTION 'invalid role %', p_role USING ERRCODE = '22023';
  END IF;
  IF COALESCE(length(p_password), 0) < 8 THEN
    RAISE EXCEPTION 'password too short (min 8)' USING ERRCODE = '22023';
  END IF;
  INSERT INTO public.admin_operators(username, password_hash, role)
  VALUES (lower(p_username), crypt(p_password, gen_salt('bf')), p_role)
  RETURNING id INTO v_id;
  PERFORM public.admin_write_audit(p_by, 'operator_add', 'operator', v_id::text,
                                   jsonb_build_object('username', lower(p_username), 'role', p_role));
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_operator_set_disabled(
  p_id UUID, p_disabled BOOLEAN, p_by UUID DEFAULT NULL)
RETURNS VOID SECURITY DEFINER SET search_path = public, pg_temp LANGUAGE plpgsql AS $$
BEGIN
  UPDATE public.admin_operators SET disabled_at = CASE WHEN p_disabled THEN now() ELSE NULL END
  WHERE id = p_id;
  PERFORM public.admin_write_audit(p_by, CASE WHEN p_disabled THEN 'operator_disable' ELSE 'operator_enable' END,
                                   'operator', p_id::text, NULL);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_operator_set_role(
  p_id UUID, p_role TEXT, p_by UUID DEFAULT NULL)
RETURNS VOID SECURITY DEFINER SET search_path = public, pg_temp LANGUAGE plpgsql AS $$
BEGIN
  IF p_role NOT IN ('admin', 'moderator') THEN
    RAISE EXCEPTION 'invalid role %', p_role USING ERRCODE = '22023';
  END IF;
  UPDATE public.admin_operators SET role = p_role WHERE id = p_id;
  PERFORM public.admin_write_audit(p_by, 'operator_set_role', 'operator', p_id::text,
                                   jsonb_build_object('role', p_role));
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_operator_set_password(
  p_id UUID, p_password TEXT, p_by UUID DEFAULT NULL)
RETURNS VOID SECURITY DEFINER SET search_path = public, extensions, pg_temp LANGUAGE plpgsql AS $$
BEGIN
  IF COALESCE(length(p_password), 0) < 8 THEN
    RAISE EXCEPTION 'password too short (min 8)' USING ERRCODE = '22023';
  END IF;
  UPDATE public.admin_operators SET password_hash = crypt(p_password, gen_salt('bf')) WHERE id = p_id;
  PERFORM public.admin_write_audit(p_by, 'operator_set_password', 'operator', p_id::text, NULL);
END;
$$;

-- ----------------------------------------------------------------------------
-- 6. Settings RPCs
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_settings_get()
RETURNS TABLE(key TEXT, value JSONB)
SECURITY DEFINER SET search_path = public, pg_temp LANGUAGE sql STABLE AS $$
  SELECT key, value FROM public.admin_settings ORDER BY key;
$$;

CREATE OR REPLACE FUNCTION public.admin_settings_set(p_key TEXT, p_value JSONB, p_by UUID DEFAULT NULL)
RETURNS VOID SECURITY DEFINER SET search_path = public, pg_temp LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO public.admin_settings(key, value, updated_at) VALUES (p_key, p_value, now())
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
  PERFORM public.admin_write_audit(p_by, 'settings_set', 'setting', p_key,
                                   jsonb_build_object('value', p_value));
END;
$$;

-- ----------------------------------------------------------------------------
-- 7. Watchlist RPCs (lists + terms + import/export)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.moderation_lists_list()
RETURNS TABLE(id UUID, name TEXT, description TEXT, source TEXT, enabled BOOLEAN,
              term_count BIGINT, created_at TIMESTAMPTZ)
SECURITY DEFINER SET search_path = public, pg_temp LANGUAGE sql STABLE AS $$
  SELECT l.id, l.name, l.description, l.source, l.enabled,
         (SELECT COUNT(*) FROM public.moderation_terms t WHERE t.list_id = l.id),
         l.created_at
  FROM public.moderation_lists l ORDER BY l.created_at;
$$;

CREATE OR REPLACE FUNCTION public.moderation_list_terms(p_list_id UUID)
RETURNS TABLE(id UUID, pattern TEXT, category TEXT, created_at TIMESTAMPTZ)
SECURITY DEFINER SET search_path = public, pg_temp LANGUAGE sql STABLE AS $$
  SELECT id, pattern, category, created_at FROM public.moderation_terms
  WHERE list_id = p_list_id ORDER BY created_at;
$$;

CREATE OR REPLACE FUNCTION public.moderation_list_add(
  p_name TEXT, p_description TEXT DEFAULT NULL, p_source TEXT DEFAULT 'custom', p_by UUID DEFAULT NULL)
RETURNS UUID SECURITY DEFINER SET search_path = public, pg_temp LANGUAGE plpgsql AS $$
DECLARE v_id UUID;
BEGIN
  INSERT INTO public.moderation_lists(name, description, source)
  VALUES (p_name, p_description, CASE WHEN p_source = 'preset' THEN 'preset' ELSE 'custom' END)
  RETURNING id INTO v_id;
  PERFORM public.admin_write_audit(p_by, 'list_add', 'list', v_id::text,
                                   jsonb_build_object('name', p_name));
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.moderation_list_rename(
  p_id UUID, p_name TEXT, p_description TEXT DEFAULT NULL, p_by UUID DEFAULT NULL)
RETURNS VOID SECURITY DEFINER SET search_path = public, pg_temp LANGUAGE plpgsql AS $$
BEGIN
  UPDATE public.moderation_lists SET name = p_name, description = p_description WHERE id = p_id;
  PERFORM public.admin_write_audit(p_by, 'list_rename', 'list', p_id::text,
                                   jsonb_build_object('name', p_name));
END;
$$;

CREATE OR REPLACE FUNCTION public.moderation_list_set_enabled(
  p_id UUID, p_enabled BOOLEAN, p_by UUID DEFAULT NULL)
RETURNS VOID SECURITY DEFINER SET search_path = public, pg_temp LANGUAGE plpgsql AS $$
BEGIN
  UPDATE public.moderation_lists SET enabled = p_enabled WHERE id = p_id;
  PERFORM public.admin_write_audit(p_by, CASE WHEN p_enabled THEN 'list_enable' ELSE 'list_disable' END,
                                   'list', p_id::text, NULL);
END;
$$;

CREATE OR REPLACE FUNCTION public.moderation_list_delete(p_id UUID, p_by UUID DEFAULT NULL)
RETURNS VOID SECURITY DEFINER SET search_path = public, pg_temp LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM public.moderation_lists WHERE id = p_id;   -- cascades terms
  PERFORM public.admin_write_audit(p_by, 'list_delete', 'list', p_id::text, NULL);
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
  INSERT INTO public.moderation_terms(list_id, pattern, category)
  VALUES (p_list_id, p_pattern, COALESCE(p_category, 'other'))
  RETURNING id INTO v_id;
  PERFORM public.admin_write_audit(p_by, 'term_add', 'term', v_id::text,
                                   jsonb_build_object('list_id', p_list_id, 'pattern', p_pattern));
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.moderation_term_remove(p_id UUID, p_by UUID DEFAULT NULL)
RETURNS VOID SECURITY DEFINER SET search_path = public, pg_temp LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM public.moderation_terms WHERE id = p_id;
  PERFORM public.admin_write_audit(p_by, 'term_remove', 'term', p_id::text, NULL);
END;
$$;

-- Export a list (meta + terms) as JSON; import creates a list + bulk-inserts.
CREATE OR REPLACE FUNCTION public.moderation_list_export(p_list_id UUID)
RETURNS JSONB SECURITY DEFINER SET search_path = public, pg_temp LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'name', l.name, 'description', l.description, 'source', l.source,
    'terms', COALESCE((SELECT jsonb_agg(jsonb_build_object('pattern', t.pattern, 'category', t.category)
                               ORDER BY t.created_at)
                        FROM public.moderation_terms t WHERE t.list_id = l.id), '[]'::jsonb))
  FROM public.moderation_lists l WHERE l.id = p_list_id;
$$;

CREATE OR REPLACE FUNCTION public.moderation_list_import(p_payload JSONB, p_by UUID DEFAULT NULL)
RETURNS UUID SECURITY DEFINER SET search_path = public, pg_temp LANGUAGE plpgsql AS $$
DECLARE v_list UUID; v_count INT;
BEGIN
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

-- ----------------------------------------------------------------------------
-- 8. Enforcement lists (Users/Enforcement tab) + transparency + audit list
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mod_banned_users_list()
RETURNS TABLE(user_id UUID, username TEXT, banned_at TIMESTAMPTZ)
SECURITY DEFINER SET search_path = public, pg_temp LANGUAGE sql STABLE AS $$
  SELECT id, username, banned_at FROM public.profiles
  WHERE banned_at IS NOT NULL ORDER BY banned_at DESC;
$$;

CREATE OR REPLACE FUNCTION public.mod_banned_chats_list()
RETURNS TABLE(chat_id UUID, name TEXT, banned_at TIMESTAMPTZ)
SECURITY DEFINER SET search_path = public, pg_temp LANGUAGE sql STABLE AS $$
  SELECT id, name, banned_at FROM public.chats
  WHERE banned_at IS NOT NULL ORDER BY banned_at DESC;
$$;

CREATE OR REPLACE FUNCTION public.mod_flagging_revoked_list()
RETURNS TABLE(user_id UUID, username TEXT, false_flags INT, flagging_revoked_at TIMESTAMPTZ)
SECURITY DEFINER SET search_path = public, pg_temp LANGUAGE sql STABLE AS $$
  SELECT id, username, false_flags, flagging_revoked_at FROM public.profiles
  WHERE flagging_revoked_at IS NOT NULL ORDER BY flagging_revoked_at DESC;
$$;

-- Anonymous aggregate for the transparency export / public report.
CREATE OR REPLACE FUNCTION public.metrics_transparency()
RETURNS TABLE(metric TEXT, value BIGINT)
SECURITY DEFINER SET search_path = public, pg_temp LANGUAGE sql STABLE AS $$
  SELECT 'accounts_total',  COUNT(*)::bigint FROM public.profiles
  UNION ALL SELECT 'reports_received', COUNT(*)::bigint FROM public.reports
  UNION ALL SELECT 'reports_upheld',   COUNT(*)::bigint FROM public.reports WHERE resolution = 'upheld'
  UNION ALL SELECT 'users_banned',     COUNT(*)::bigint FROM public.profiles WHERE banned_at IS NOT NULL
  UNION ALL SELECT 'groups_banned',    COUNT(*)::bigint FROM public.chats    WHERE banned_at IS NOT NULL;
$$;

CREATE OR REPLACE FUNCTION public.admin_audit_list(p_limit INT DEFAULT 200)
RETURNS TABLE(id BIGINT, operator_label TEXT, action TEXT, target_type TEXT,
              target_id TEXT, detail JSONB, created_at TIMESTAMPTZ)
SECURITY DEFINER SET search_path = public, pg_temp LANGUAGE sql STABLE AS $$
  SELECT id, operator_label, action, target_type, target_id, detail, created_at
  FROM public.admin_audit ORDER BY id DESC LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 200), 1000));
$$;

-- ----------------------------------------------------------------------------
-- 9. CREATE OR REPLACE 00060 fns: enabled-list scan + settings-driven thresholds
-- ----------------------------------------------------------------------------
-- abuse_signals: name-watchlist branches now scan ONLY terms from ENABLED lists.
CREATE OR REPLACE FUNCTION public.abuse_signals()
RETURNS TABLE(kind TEXT, subject_id UUID, label TEXT, detail TEXT, score BIGINT)
SECURITY DEFINER SET search_path = public, pg_temp LANGUAGE sql STABLE AS $$
  SELECT 'mass_block', b.blocked_id, p.username, 'blocked by N distinct users',
         COUNT(DISTINCT b.blocker_id)::bigint
  FROM public.blocked_users b JOIN public.profiles p ON p.id = b.blocked_id
  GROUP BY b.blocked_id, p.username
  HAVING COUNT(DISTINCT b.blocker_id) >= 3
  UNION ALL
  SELECT 'name_user', p.id, p.username, 'username matches watchlist ('||t.category||')', 1
  FROM public.profiles p
  JOIN public.moderation_terms t ON p.username ~* t.pattern
  JOIN public.moderation_lists l ON l.id = t.list_id AND l.enabled
  UNION ALL
  SELECT 'name_group', c.id, c.name, 'group name/description matches watchlist ('||t.category||')', 1
  FROM public.chats c
  JOIN public.moderation_terms t ON (c.name ~* t.pattern OR COALESCE(c.description,'') ~* t.pattern)
  JOIN public.moderation_lists l ON l.id = t.list_id AND l.enabled
  ORDER BY 5 DESC;
$$;

-- content gate cap now read from admin_settings (fallback 3).
CREATE OR REPLACE FUNCTION public.report_reveal_gate_open(p_message_id UUID)
RETURNS BOOLEAN SECURITY DEFINER SET search_path = public, pg_temp LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_recipients INT;
  v_reporters  INT;
  v_threshold  INT;
BEGIN
  SELECT COUNT(*) INTO v_recipients FROM public.messages m
    WHERE m.id = p_message_id AND m.recipient_id IS DISTINCT FROM m.sender_id;
  IF v_recipients = 0 THEN v_recipients := 1; END IF;
  v_threshold := LEAST(public.admin_setting_int('content_gate_cap', 3), v_recipients);
  SELECT COUNT(DISTINCT reporter_id) INTO v_reporters FROM public.reports
    WHERE message_id = p_message_id;
  RETURN v_reporters >= v_threshold;
END;
$$;

-- mod_* now take an optional operator (p_by) and write an audit row. Drop the
-- old single-arg signatures first so there's exactly ONE overload; a call that
-- passes only the target still works via the p_by DEFAULT (legacy edge fn).
DROP FUNCTION IF EXISTS public.mod_ban_user(uuid);
DROP FUNCTION IF EXISTS public.mod_unban_user(uuid);
DROP FUNCTION IF EXISTS public.mod_ban_chat(uuid);
DROP FUNCTION IF EXISTS public.mod_unban_chat(uuid);
DROP FUNCTION IF EXISTS public.mod_resolve_report(uuid, text);
DROP FUNCTION IF EXISTS public.mod_restore_flagging(uuid);

CREATE FUNCTION public.mod_ban_user(p_user UUID, p_by UUID DEFAULT NULL)
RETURNS VOID SECURITY DEFINER SET search_path = public, pg_temp LANGUAGE plpgsql AS $$
BEGIN
  UPDATE public.profiles SET banned_at = now() WHERE id = p_user;
  DELETE FROM public.device_tokens WHERE user_id = p_user;   -- silence push
  PERFORM public.admin_write_audit(p_by, 'ban_user', 'user', p_user::text, NULL);
END;
$$;

CREATE FUNCTION public.mod_unban_user(p_user UUID, p_by UUID DEFAULT NULL)
RETURNS VOID SECURITY DEFINER SET search_path = public, pg_temp LANGUAGE plpgsql AS $$
BEGIN
  UPDATE public.profiles SET banned_at = NULL WHERE id = p_user;
  PERFORM public.admin_write_audit(p_by, 'unban_user', 'user', p_user::text, NULL);
END;
$$;

CREATE FUNCTION public.mod_ban_chat(p_chat UUID, p_by UUID DEFAULT NULL)
RETURNS VOID SECURITY DEFINER SET search_path = public, pg_temp LANGUAGE plpgsql AS $$
BEGIN
  UPDATE public.chats SET banned_at = now() WHERE id = p_chat;
  PERFORM public.admin_write_audit(p_by, 'ban_chat', 'chat', p_chat::text, NULL);
END;
$$;

CREATE FUNCTION public.mod_unban_chat(p_chat UUID, p_by UUID DEFAULT NULL)
RETURNS VOID SECURITY DEFINER SET search_path = public, pg_temp LANGUAGE plpgsql AS $$
BEGIN
  UPDATE public.chats SET banned_at = NULL WHERE id = p_chat;
  PERFORM public.admin_write_audit(p_by, 'unban_chat', 'chat', p_chat::text, NULL);
END;
$$;

CREATE FUNCTION public.mod_resolve_report(p_report_id UUID, p_resolution TEXT, p_by UUID DEFAULT NULL)
RETURNS VOID SECURITY DEFINER SET search_path = public, pg_temp LANGUAGE plpgsql AS $$
DECLARE
  v_reporter UUID;
  v_strikes  INT;
  v_threshold INT := public.admin_setting_int('false_flag_threshold', 3);
  v_decay    INTERVAL := make_interval(months => public.admin_setting_int('false_flag_decay_months', 6));
BEGIN
  IF p_resolution NOT IN ('upheld', 'unfounded', 'dismissed', 'open') THEN
    RAISE EXCEPTION 'invalid resolution %', p_resolution USING ERRCODE = '22023';
  END IF;

  UPDATE public.reports
  SET resolution = p_resolution,
      resolved_at = CASE WHEN p_resolution = 'open' THEN NULL ELSE now() END,
      revealed_text = CASE WHEN p_resolution = 'open' THEN revealed_text ELSE NULL END,
      revealed_sig  = CASE WHEN p_resolution = 'open' THEN revealed_sig  ELSE NULL END,
      revealed_identity_key = CASE WHEN p_resolution = 'open' THEN revealed_identity_key ELSE NULL END
  WHERE id = p_report_id
  RETURNING reporter_id INTO v_reporter;

  IF p_resolution = 'unfounded' AND v_reporter IS NOT NULL THEN
    SELECT CASE WHEN last_false_flag_at < now() - v_decay THEN 1
                ELSE false_flags + 1 END
    INTO v_strikes FROM public.profiles WHERE id = v_reporter;
    v_strikes := COALESCE(v_strikes, 1);

    UPDATE public.profiles
    SET false_flags = v_strikes,
        last_false_flag_at = now(),
        flagging_revoked_at = CASE WHEN v_strikes >= v_threshold THEN now()
                                   ELSE flagging_revoked_at END
    WHERE id = v_reporter;
  END IF;

  PERFORM public.admin_write_audit(p_by, 'resolve_report', 'report', p_report_id::text,
                                   jsonb_build_object('resolution', p_resolution));
END;
$$;

CREATE FUNCTION public.mod_restore_flagging(p_user UUID, p_by UUID DEFAULT NULL)
RETURNS VOID SECURITY DEFINER SET search_path = public, pg_temp LANGUAGE plpgsql AS $$
BEGIN
  UPDATE public.profiles SET flagging_revoked_at = NULL, false_flags = 0 WHERE id = p_user;
  PERFORM public.admin_write_audit(p_by, 'restore_flagging', 'user', p_user::text, NULL);
END;
$$;

-- ----------------------------------------------------------------------------
-- 10. Grants — everything here is service_role only; internal helpers locked.
-- ----------------------------------------------------------------------------
DO $$
DECLARE fn text;
BEGIN
  -- moderator / operator RPCs → service_role (edge fn) only
  FOREACH fn IN ARRAY ARRAY[
    'admin_operator_count()',
    'admin_login(text,text)',
    'admin_operators_list()',
    'admin_operator_add(text,text,text,uuid)',
    'admin_operator_set_disabled(uuid,boolean,uuid)',
    'admin_operator_set_role(uuid,text,uuid)',
    'admin_operator_set_password(uuid,text,uuid)',
    'admin_settings_get()',
    'admin_settings_set(text,jsonb,uuid)',
    'moderation_lists_list()',
    'moderation_list_terms(uuid)',
    'moderation_list_add(text,text,text,uuid)',
    'moderation_list_rename(uuid,text,text,uuid)',
    'moderation_list_set_enabled(uuid,boolean,uuid)',
    'moderation_list_delete(uuid,uuid)',
    'moderation_term_add(uuid,text,text,uuid)',
    'moderation_term_remove(uuid,uuid)',
    'moderation_list_export(uuid)',
    'moderation_list_import(jsonb,uuid)',
    'mod_banned_users_list()',
    'mod_banned_chats_list()',
    'mod_flagging_revoked_list()',
    'metrics_transparency()',
    'admin_audit_list(integer)',
    'abuse_signals()',
    'report_reveal_gate_open(uuid)',
    'mod_ban_user(uuid,uuid)', 'mod_unban_user(uuid,uuid)',
    'mod_ban_chat(uuid,uuid)', 'mod_unban_chat(uuid,uuid)',
    'mod_resolve_report(uuid,text,uuid)', 'mod_restore_flagging(uuid,uuid)'
  ] LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION public.%s FROM PUBLIC, anon, authenticated', fn);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO service_role', fn);
  END LOOP;

  -- internal-only helpers (called only from other SECURITY DEFINER fns)
  FOREACH fn IN ARRAY ARRAY[
    'admin_write_audit(uuid,text,text,text,jsonb)',
    'admin_setting_int(text,integer)'
  ] LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION public.%s FROM PUBLIC, anon, authenticated, service_role', fn);
  END LOOP;
END;
$$;
