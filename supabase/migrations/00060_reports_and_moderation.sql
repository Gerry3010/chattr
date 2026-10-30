-- SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
-- SPDX-License-Identifier: AGPL-3.0-or-later

-- ============================================================================
-- 00060: Moderation MVP — content-blind reporting + enforcement
-- ----------------------------------------------------------------------------
-- Chattr is E2E: the server NEVER decrypts a message, not even for moderation.
-- This layer works only on METADATA + evidence a participant chooses to reveal:
--
--  * A flag transmits ONLY {message_id, chat_id, reason} — no content.
--  * Message content enters a report solely via reveal_reported_message():
--      - the ACCUSED sender may self-reveal at any time (signs the plaintext
--        with their identity key → self-authenticating + plaintext-bound), or
--      - a RECIPIENT may attach their received copy once the content gate opens:
--        distinct reporters >= min(3, N), N = recipients excluding the sender
--        (1:1 → N=1 → immediate; group → up to 3). User-level reports (no
--        message) never unlock recipient content — flat corroboration only.
--  * Group/username reports act on PLAINTEXT identifiers (chats.name/description,
--    profiles.username) which are already server-visible metadata — NOT content.
--    A name watchlist scans ONLY those identifiers, never a message → this is
--    explicitly NOT client-side scanning; the CSS pledge stays intact.
--  * Enforcement is content-blind: profiles.banned_at / chats.banned_at + guard
--    triggers (mirroring 00031) reject a banned actor's inserts globally.
--  * False reporting is punished: a moderator-confirmed 'unfounded' resolution
--    is a strike; FALSE_FLAG_THRESHOLD confirmed-false → flagging revoked
--    (decays after FALSE_FLAG_DECAY). Only 'unfounded' counts — not "unhandled".
--
-- Moderator access is service_role-only (the admin-stats edge fn); there is NO
-- in-app moderator role (a single operator) → minimal attack surface.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Enforcement columns + helpers
-- ----------------------------------------------------------------------------
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS banned_at TIMESTAMPTZ;
ALTER TABLE public.chats    ADD COLUMN IF NOT EXISTS banned_at TIMESTAMPTZ;

-- False-flag bookkeeping (rough decay via last-strike timestamp; see resolve).
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS false_flags INT NOT NULL DEFAULT 0;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS last_false_flag_at TIMESTAMPTZ;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS flagging_revoked_at TIMESTAMPTZ;

COMMENT ON COLUMN public.profiles.banned_at IS 'Account suspension (content-blind): guard triggers reject a banned user''s message/membership inserts. Set via mod_ban_user.';
COMMENT ON COLUMN public.chats.banned_at IS 'Group suspension: guard triggers reject inserts targeting a banned chat. Set via mod_ban_chat.';

CREATE OR REPLACE FUNCTION public.is_banned(p_user UUID)
RETURNS BOOLEAN SECURITY DEFINER SET search_path = public, pg_temp LANGUAGE sql STABLE AS $$
  SELECT EXISTS (SELECT 1 FROM public.profiles WHERE id = p_user AND banned_at IS NOT NULL);
$$;

CREATE OR REPLACE FUNCTION public.is_chat_banned(p_chat UUID)
RETURNS BOOLEAN SECURITY DEFINER SET search_path = public, pg_temp LANGUAGE sql STABLE AS $$
  SELECT EXISTS (SELECT 1 FROM public.chats WHERE id = p_chat AND banned_at IS NOT NULL);
$$;

-- Guard: a banned sender can't send; nobody can post into a banned chat.
CREATE OR REPLACE FUNCTION public.guard_banned_message()
RETURNS TRIGGER SECURITY DEFINER SET search_path = public, pg_temp LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.sender_id IS NOT NULL AND public.is_banned(NEW.sender_id) THEN
    RAISE EXCEPTION 'banned: this account is suspended' USING ERRCODE = 'check_violation';
  END IF;
  IF public.is_chat_banned(NEW.chat_id) THEN
    RAISE EXCEPTION 'banned: this chat is suspended' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS guard_banned_message_trigger ON public.messages;
CREATE TRIGGER guard_banned_message_trigger
  BEFORE INSERT ON public.messages FOR EACH ROW
  EXECUTE FUNCTION public.guard_banned_message();

-- Guard: a banned user can't (re)join; nobody joins a banned chat.
CREATE OR REPLACE FUNCTION public.guard_banned_membership()
RETURNS TRIGGER SECURITY DEFINER SET search_path = public, pg_temp LANGUAGE plpgsql AS $$
BEGIN
  IF public.is_banned(NEW.user_id) THEN
    RAISE EXCEPTION 'banned: this account is suspended' USING ERRCODE = 'check_violation';
  END IF;
  IF public.is_chat_banned(NEW.chat_id) THEN
    RAISE EXCEPTION 'banned: this chat is suspended' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS guard_banned_membership_trigger ON public.chat_members;
CREATE TRIGGER guard_banned_membership_trigger
  BEFORE INSERT ON public.chat_members FOR EACH ROW
  EXECUTE FUNCTION public.guard_banned_membership();

DROP TRIGGER IF EXISTS guard_banned_pending_trigger ON public.pending_chat_members;
CREATE TRIGGER guard_banned_pending_trigger
  BEFORE INSERT ON public.pending_chat_members FOR EACH ROW
  EXECUTE FUNCTION public.guard_banned_membership();

-- ----------------------------------------------------------------------------
-- 2. Watchlist terms (DB data, never committed to the repo — kept out of the
--    public codebase so the list isn't a gameable artifact). service_role only.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.moderation_terms (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  pattern    TEXT NOT NULL,               -- POSIX regex, matched case-insensitively
  category   TEXT NOT NULL DEFAULT 'other',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.moderation_terms ENABLE ROW LEVEL SECURITY; -- deny-all

-- ----------------------------------------------------------------------------
-- 3. Reports table
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.reports (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  reporter_id           UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  subject_type          TEXT NOT NULL CHECK (subject_type IN ('user', 'group')),
  reported_user_id      UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  reported_chat_id      UUID REFERENCES public.chats(id) ON DELETE CASCADE,
  message_id            UUID,                       -- no FK: messages self-prune
  chat_id               UUID REFERENCES public.chats(id) ON DELETE SET NULL,
  reason                TEXT NOT NULL,
  resolution            TEXT NOT NULL DEFAULT 'open'
                          CHECK (resolution IN ('open', 'upheld', 'unfounded', 'dismissed')),
  revealed_text         TEXT,                       -- only via reveal_reported_message
  revealed_by           TEXT CHECK (revealed_by IN ('sender', 'recipient')),
  revealed_sig          TEXT,
  revealed_identity_key TEXT,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  resolved_at           TIMESTAMPTZ,
  CONSTRAINT reports_subject_shape CHECK (
    (subject_type = 'user'  AND reported_user_id IS NOT NULL AND reported_chat_id IS NULL)
    OR (subject_type = 'group' AND reported_chat_id IS NOT NULL AND reported_user_id IS NULL)
  )
);

-- Dedupe: one flag per reporter per message / per user / per group.
CREATE UNIQUE INDEX IF NOT EXISTS uq_reports_reporter_message
  ON public.reports (reporter_id, message_id) WHERE message_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_reports_reporter_user
  ON public.reports (reporter_id, reported_user_id) WHERE message_id IS NULL AND reported_user_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_reports_reporter_group
  ON public.reports (reporter_id, reported_chat_id) WHERE reported_chat_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_reports_open ON public.reports (created_at) WHERE resolution = 'open';
CREATE INDEX IF NOT EXISTS idx_reports_message ON public.reports (message_id) WHERE message_id IS NOT NULL;

ALTER TABLE public.reports ENABLE ROW LEVEL SECURITY;

-- Reporter may create a report only for a chat they belong to (no flagging
-- strangers), forced to their own reporter_id, and only revealed_* left empty.
CREATE POLICY "Reporter inserts own report"
ON public.reports FOR INSERT TO authenticated
WITH CHECK (
  reporter_id = auth.uid()
  AND revealed_text IS NULL AND revealed_sig IS NULL AND resolution = 'open'
  AND (
    (subject_type = 'group' AND is_chat_member(reported_chat_id, auth.uid()))
    OR (subject_type = 'user' AND chat_id IS NOT NULL AND is_chat_member(chat_id, auth.uid()))
  )
);

-- Reporter may read only their own reports; moderator reads via service_role.
CREATE POLICY "Reporter reads own reports"
ON public.reports FOR SELECT TO authenticated
USING (reporter_id = auth.uid());

-- Reject flags from a user whose flagging privilege was revoked.
CREATE OR REPLACE FUNCTION public.guard_report_insert()
RETURNS TRIGGER SECURITY DEFINER SET search_path = public, pg_temp LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.profiles
             WHERE id = NEW.reporter_id AND flagging_revoked_at IS NOT NULL) THEN
    RAISE EXCEPTION 'reporting disabled for this account' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS guard_report_insert_trigger ON public.reports;
CREATE TRIGGER guard_report_insert_trigger
  BEFORE INSERT ON public.reports FOR EACH ROW
  EXECUTE FUNCTION public.guard_report_insert();

-- ----------------------------------------------------------------------------
-- 4. Content gate + reveal. min(3, N) where N = recipients excluding sender.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.report_reveal_gate_open(p_message_id UUID)
RETURNS BOOLEAN SECURITY DEFINER SET search_path = public, pg_temp LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_recipients INT;
  v_reporters  INT;
  v_threshold  INT;
BEGIN
  SELECT COUNT(*) INTO v_recipients FROM public.messages m
    WHERE m.id = p_message_id AND m.recipient_id IS DISTINCT FROM m.sender_id;
  IF v_recipients = 0 THEN v_recipients := 1; END IF;          -- fail safe
  v_threshold := LEAST(3, v_recipients);
  SELECT COUNT(DISTINCT reporter_id) INTO v_reporters FROM public.reports
    WHERE message_id = p_message_id;
  RETURN v_reporters >= v_threshold;
END;
$$;

-- Called by clients. Sender self-reveal any time; recipient reveal once the gate
-- is open. Writes the volunteered plaintext + attestation onto EVERY open report
-- for that message (they all describe the same message).
CREATE OR REPLACE FUNCTION public.reveal_reported_message(
  p_report_id UUID, p_text TEXT, p_sig TEXT DEFAULT NULL, p_identity_key TEXT DEFAULT NULL)
RETURNS VOID SECURITY DEFINER SET search_path = public, pg_temp LANGUAGE plpgsql AS $$
DECLARE
  v_message_id UUID;
  v_is_sender  BOOLEAN;
  v_is_recip   BOOLEAN;
  v_by         TEXT;
BEGIN
  SELECT message_id INTO v_message_id FROM public.reports WHERE id = p_report_id;
  IF v_message_id IS NULL THEN
    RAISE EXCEPTION 'report has no message to reveal' USING ERRCODE = '22023';
  END IF;

  SELECT EXISTS (SELECT 1 FROM public.messages m
                 WHERE m.id = v_message_id AND m.sender_id = auth.uid()) INTO v_is_sender;
  SELECT EXISTS (SELECT 1 FROM public.messages m
                 WHERE m.id = v_message_id AND m.recipient_id = auth.uid()) INTO v_is_recip;

  IF v_is_sender THEN
    v_by := 'sender';
  ELSIF v_is_recip AND public.report_reveal_gate_open(v_message_id) THEN
    v_by := 'recipient';
  ELSE
    RAISE EXCEPTION 'not authorized to reveal (gate not open)' USING ERRCODE = '42501';
  END IF;

  UPDATE public.reports
  SET revealed_text = p_text, revealed_sig = p_sig,
      revealed_identity_key = p_identity_key, revealed_by = v_by
  WHERE message_id = v_message_id AND resolution = 'open';
END;
$$;

-- The accused's "you were reported" signal: the caller's own sent messages that
-- currently have an open, not-yet-revealed report → the app offers a self-reveal.
CREATE OR REPLACE FUNCTION public.my_reported_messages()
RETURNS TABLE(report_id UUID, message_id UUID, chat_id UUID, reason TEXT, created_at TIMESTAMPTZ)
SECURITY DEFINER SET search_path = public, pg_temp LANGUAGE sql STABLE AS $$
  SELECT DISTINCT ON (r.message_id) r.id, r.message_id, r.chat_id, r.reason, r.created_at
  FROM public.reports r
  WHERE r.message_id IS NOT NULL
    AND r.resolution = 'open'
    AND r.revealed_text IS NULL
    AND EXISTS (SELECT 1 FROM public.messages m
                WHERE m.id = r.message_id AND m.sender_id = auth.uid())
  ORDER BY r.message_id, r.created_at;
$$;

-- ----------------------------------------------------------------------------
-- 5. Moderator RPCs (service_role only) — queue, signals, actions.
-- ----------------------------------------------------------------------------

-- Queue: one row per report with resolved context (plaintext name for groups,
-- username for users), corroboration count, reveal state. Never message content
-- unless someone already revealed it.
CREATE OR REPLACE FUNCTION public.mod_report_queue(p_include_resolved BOOLEAN DEFAULT false)
RETURNS TABLE(
  id UUID, subject_type TEXT, reason TEXT, resolution TEXT, created_at TIMESTAMPTZ,
  reported_user_id UUID, reported_username TEXT,
  reported_chat_id UUID, group_name TEXT, group_description TEXT, group_admins UUID[],
  message_id UUID, chat_id UUID,
  distinct_reporters BIGINT, gate_open BOOLEAN,
  revealed_text TEXT, revealed_by TEXT, revealed_sig TEXT, revealed_identity_key TEXT,
  reported_identity_key TEXT)
SECURITY DEFINER SET search_path = public, pg_temp LANGUAGE sql STABLE AS $$
  SELECT r.id, r.subject_type, r.reason, r.resolution, r.created_at,
         r.reported_user_id, pu.username,
         r.reported_chat_id, c.name, c.description, c.admins,
         r.message_id, r.chat_id,
         (SELECT COUNT(DISTINCT r2.reporter_id) FROM public.reports r2
            WHERE (r.message_id IS NOT NULL AND r2.message_id = r.message_id)
               OR (r.message_id IS NULL AND r.reported_user_id IS NOT NULL AND r2.reported_user_id = r.reported_user_id)
               OR (r.reported_chat_id IS NOT NULL AND r2.reported_chat_id = r.reported_chat_id)),
         CASE WHEN r.message_id IS NOT NULL THEN public.report_reveal_gate_open(r.message_id) ELSE NULL END,
         r.revealed_text, r.revealed_by, r.revealed_sig, r.revealed_identity_key,
         psub.identity_public_key
  FROM public.reports r
  LEFT JOIN public.profiles pu   ON pu.id = r.reported_user_id
  LEFT JOIN public.profiles psub ON psub.id = r.reported_user_id
  LEFT JOIN public.chats c       ON c.id = r.reported_chat_id
  WHERE p_include_resolved OR r.resolution = 'open'
  ORDER BY r.created_at DESC;
$$;

-- Behavioural + name signals (no report needed). Mass-block + watchlist hits on
-- PLAINTEXT identifiers only (never message content).
CREATE OR REPLACE FUNCTION public.abuse_signals()
RETURNS TABLE(kind TEXT, subject_id UUID, label TEXT, detail TEXT, score BIGINT)
SECURITY DEFINER SET search_path = public, pg_temp LANGUAGE sql STABLE AS $$
  -- mass-block: users blocked by many DISTINCT others
  SELECT 'mass_block', b.blocked_id, p.username, 'blocked by N distinct users',
         COUNT(DISTINCT b.blocker_id)::bigint
  FROM public.blocked_users b JOIN public.profiles p ON p.id = b.blocked_id
  GROUP BY b.blocked_id, p.username
  HAVING COUNT(DISTINCT b.blocker_id) >= 3
  UNION ALL
  -- watchlist hit on a username
  SELECT 'name_user', p.id, p.username, 'username matches watchlist ('||t.category||')', 1
  FROM public.profiles p JOIN public.moderation_terms t ON p.username ~* t.pattern
  UNION ALL
  -- watchlist hit on a group name / description
  SELECT 'name_group', c.id, c.name, 'group name/description matches watchlist ('||t.category||')', 1
  FROM public.chats c JOIN public.moderation_terms t
    ON (c.name ~* t.pattern OR COALESCE(c.description,'') ~* t.pattern)
  ORDER BY 5 DESC;
$$;

-- Ban / unban.
CREATE OR REPLACE FUNCTION public.mod_ban_user(p_user UUID)
RETURNS VOID SECURITY DEFINER SET search_path = public, pg_temp LANGUAGE plpgsql AS $$
BEGIN
  UPDATE public.profiles SET banned_at = now() WHERE id = p_user;
  DELETE FROM public.device_tokens WHERE user_id = p_user;   -- silence push
END;
$$;
CREATE OR REPLACE FUNCTION public.mod_unban_user(p_user UUID)
RETURNS VOID SECURITY DEFINER SET search_path = public, pg_temp LANGUAGE sql AS $$
  UPDATE public.profiles SET banned_at = NULL WHERE id = p_user;
$$;
CREATE OR REPLACE FUNCTION public.mod_ban_chat(p_chat UUID)
RETURNS VOID SECURITY DEFINER SET search_path = public, pg_temp LANGUAGE sql AS $$
  UPDATE public.chats SET banned_at = now() WHERE id = p_chat;
$$;
CREATE OR REPLACE FUNCTION public.mod_unban_chat(p_chat UUID)
RETURNS VOID SECURITY DEFINER SET search_path = public, pg_temp LANGUAGE sql AS $$
  UPDATE public.chats SET banned_at = NULL WHERE id = p_chat;
$$;

-- Resolve a report. 'unfounded' = moderator-confirmed FALSE → strike the
-- reporter (decays: a strike older than 6 months resets the counter). At
-- threshold 3 → flagging revoked. Also purges any revealed content (hygiene).
CREATE OR REPLACE FUNCTION public.mod_resolve_report(p_report_id UUID, p_resolution TEXT)
RETURNS VOID SECURITY DEFINER SET search_path = public, pg_temp LANGUAGE plpgsql AS $$
DECLARE
  v_reporter UUID;
  v_strikes  INT;
  FALSE_FLAG_THRESHOLD CONSTANT INT := 3;
  FALSE_FLAG_DECAY CONSTANT INTERVAL := INTERVAL '6 months';
BEGIN
  IF p_resolution NOT IN ('upheld', 'unfounded', 'dismissed', 'open') THEN
    RAISE EXCEPTION 'invalid resolution %', p_resolution USING ERRCODE = '22023';
  END IF;

  UPDATE public.reports
  SET resolution = p_resolution,
      resolved_at = CASE WHEN p_resolution = 'open' THEN NULL ELSE now() END,
      -- purge volunteered content once the case is closed (data hygiene)
      revealed_text = CASE WHEN p_resolution = 'open' THEN revealed_text ELSE NULL END,
      revealed_sig  = CASE WHEN p_resolution = 'open' THEN revealed_sig  ELSE NULL END,
      revealed_identity_key = CASE WHEN p_resolution = 'open' THEN revealed_identity_key ELSE NULL END
  WHERE id = p_report_id
  RETURNING reporter_id INTO v_reporter;

  IF p_resolution = 'unfounded' AND v_reporter IS NOT NULL THEN
    SELECT CASE WHEN last_false_flag_at < now() - FALSE_FLAG_DECAY THEN 1
                ELSE false_flags + 1 END
    INTO v_strikes FROM public.profiles WHERE id = v_reporter;
    v_strikes := COALESCE(v_strikes, 1);

    UPDATE public.profiles
    SET false_flags = v_strikes,
        last_false_flag_at = now(),
        flagging_revoked_at = CASE WHEN v_strikes >= FALSE_FLAG_THRESHOLD THEN now()
                                   ELSE flagging_revoked_at END
    WHERE id = v_reporter;
  END IF;
END;
$$;

-- Manual override: restore a reporter's flagging privilege.
CREATE OR REPLACE FUNCTION public.mod_restore_flagging(p_user UUID)
RETURNS VOID SECURITY DEFINER SET search_path = public, pg_temp LANGUAGE sql AS $$
  UPDATE public.profiles SET flagging_revoked_at = NULL, false_flags = 0 WHERE id = p_user;
$$;

-- ----------------------------------------------------------------------------
-- 6. Grants. Client RPCs → authenticated; moderator RPCs → service_role only.
-- ----------------------------------------------------------------------------
DO $$
DECLARE fn text;
BEGIN
  -- client-callable (authenticated), locked away from anon/public
  FOREACH fn IN ARRAY ARRAY[
    'reveal_reported_message(uuid,text,text,text)',
    'my_reported_messages()'
  ] LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION public.%s FROM PUBLIC, anon', fn);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO authenticated', fn);
  END LOOP;

  -- moderator / internal (service_role only)
  FOREACH fn IN ARRAY ARRAY[
    'mod_report_queue(boolean)', 'abuse_signals()',
    'mod_ban_user(uuid)', 'mod_unban_user(uuid)',
    'mod_ban_chat(uuid)', 'mod_unban_chat(uuid)',
    'mod_resolve_report(uuid,text)', 'mod_restore_flagging(uuid)',
    'report_reveal_gate_open(uuid)'
  ] LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION public.%s FROM PUBLIC, anon, authenticated', fn);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO service_role', fn);
  END LOOP;

  -- internal-only helpers (triggers own them; no external caller)
  FOREACH fn IN ARRAY ARRAY[
    'is_banned(uuid)', 'is_chat_banned(uuid)'
  ] LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION public.%s FROM PUBLIC, anon, authenticated, service_role', fn);
  END LOOP;
END;
$$;
