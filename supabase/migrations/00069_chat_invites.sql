-- SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
-- SPDX-License-Identifier: AGPL-3.0-or-later

-- ============================================================================
-- 00069: Invitation messages (chat_invites) — auto-approve with a narrow scope
-- ----------------------------------------------------------------------------
-- An admin shares a group as a MESSAGE into another chat; whoever taps the
-- invitation card there joins WITHOUT an admin's consent. That inverts the previous
-- model (every join is approved, pending_chat_members) in one specific spot —
-- which is why the boundaries are drawn narrowly:
--
--  * **Only admins create** an invitation, **only admins revoke** it.
--  * **Valid only in the target chat** (target_chat_id): it can be redeemed only
--    by a member of the chat the invitation was sent into. A forwarded invitation
--    is thereby worthless — the token alone opens no door, membership of the
--    target chat is the second factor.
--  * **Group blocks still apply**: whoever was blocked for the group
--    (pending_chat_members.blocked_at) cannot get in by invitation either — with
--    auto-approve nobody looks at it any more.
--
-- Three SECURITY DEFINER functions that write membership — exactly the class
-- earlier RLS faults sat in. Hence: search_path pinned, EXECUTE only to
-- authenticated, and EVERY check has a negative test
-- (test/chat_invites_rls_test.dart).
--
-- The invitation's CONTENT (the card in the target chat) travels as an ordinary
-- end-to-end encrypted message (`_chattr_invite` envelope) — the server sees
-- nothing but ciphertext, as always. This table holds only what the server needs in
-- order to check: token, scope, revocation state. No group name, no text.
-- ============================================================================

CREATE TABLE public.chat_invites (
  token UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  -- Die Gruppe, in die eingeladen wird.
  chat_id UUID NOT NULL REFERENCES public.chats(id) ON DELETE CASCADE,
  -- The scope: ONLY members of this chat can redeem.
  target_chat_id UUID NOT NULL REFERENCES public.chats(id) ON DELETE CASCADE,
  created_by UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  revoked_at TIMESTAMPTZ,
  revoked_by UUID REFERENCES public.profiles(id) ON DELETE SET NULL
);

COMMENT ON TABLE public.chat_invites IS
  'Auto-Approve-Einladungen (1.13): Admin erstellt, Admin widerruft, einlösbar '
  'nur von Mitgliedern des target_chat_id. Inhalt der Einladung reist E2E-'
  'verschlüsselt als Nachricht; hier liegt nur der prüfbare Zustand.';

CREATE INDEX chat_invites_chat_id_idx ON public.chat_invites (chat_id);

ALTER TABLE public.chat_invites ENABLE ROW LEVEL SECURITY;

-- Reading: only admins of the invited group (for the revoke list in the group
-- info). No INSERT/UPDATE/DELETE for anybody — writing goes exclusively through
-- the three functions below.
CREATE POLICY chat_invites_select_admins ON public.chat_invites
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.chats c
      WHERE c.id = chat_invites.chat_id
        AND auth.uid() = ANY (c.admins)
    )
  );

-- ----------------------------------------------------------------------------
-- create_chat_invite: admin of the group AND member of the target chat.
-- ----------------------------------------------------------------------------
-- The target-chat membership is belt and braces: the admin could only send the
-- card into chats they are a member of anyway — but the function should not
-- have to take the client's word for it.
CREATE OR REPLACE FUNCTION public.create_chat_invite(
  p_chat_id UUID,
  p_target_chat_id UUID
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_token UUID;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM chats c
    WHERE c.id = p_chat_id AND auth.uid() = ANY (c.admins)
  ) THEN
    RAISE EXCEPTION 'only admins can create invites';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM chat_members cm
    WHERE cm.chat_id = p_target_chat_id AND cm.user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'not a member of the target chat';
  END IF;

  INSERT INTO chat_invites (chat_id, target_chat_id, created_by)
  VALUES (p_chat_id, p_target_chat_id, auth.uid())
  RETURNING token INTO v_token;

  RETURN v_token;
END;
$$;

-- ----------------------------------------------------------------------------
-- revoke_chat_invite: only admins of the invited group. Idempotent (revoking
-- twice is not an error, the first timestamp stays).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.revoke_chat_invite(p_token UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_chat_id UUID;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  SELECT chat_id INTO v_chat_id FROM chat_invites WHERE token = p_token;
  IF v_chat_id IS NULL THEN
    RAISE EXCEPTION 'invite not found';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM chats c
    WHERE c.id = v_chat_id AND auth.uid() = ANY (c.admins)
  ) THEN
    RAISE EXCEPTION 'only admins can revoke invites';
  END IF;

  UPDATE chat_invites
  SET revoked_at = NOW(), revoked_by = auth.uid()
  WHERE token = p_token AND revoked_at IS NULL;
END;
$$;

-- ----------------------------------------------------------------------------
-- redeem_chat_invite: the auto-approve. Checks in this order:
--   1. The invitation exists and is not revoked.
--   2. The caller is a member of the TARGET chat (the scope).
--   3. The caller is not blocked for the group (blocked_at).
-- Already a member is a success, not an error (the card shows "already in").
-- The insert path matches today's admin approval: pending row out, chat_members row
-- in with the public key brought along — the same triggers (member broadcast, key
-- exchange) apply unchanged.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.redeem_chat_invite(
  p_token UUID,
  p_public_key TEXT
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_invite RECORD;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  SELECT chat_id, target_chat_id, revoked_at INTO v_invite
  FROM chat_invites WHERE token = p_token;

  IF v_invite.chat_id IS NULL THEN
    RAISE EXCEPTION 'invite not found';
  END IF;
  IF v_invite.revoked_at IS NOT NULL THEN
    RAISE EXCEPTION 'invite revoked';
  END IF;

  -- The scope: only somebody who could legitimately see the card can redeem it
  -- — a member of the chat it was sent into.
  IF NOT EXISTS (
    SELECT 1 FROM chat_members cm
    WHERE cm.chat_id = v_invite.target_chat_id AND cm.user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'not a member of the target chat';
  END IF;

  -- Already in → success (idempotent), and BEFORE the block check: an existing
  -- member with an old block row should not fail.
  IF EXISTS (
    SELECT 1 FROM chat_members cm
    WHERE cm.chat_id = v_invite.chat_id AND cm.user_id = auth.uid()
  ) THEN
    RETURN v_invite.chat_id;
  END IF;

  -- The group block applies here too — with auto-approve no admin looks at it
  -- any more.
  IF EXISTS (
    SELECT 1 FROM pending_chat_members p
    WHERE p.chat_id = v_invite.chat_id
      AND p.user_id = auth.uid()
      AND p.blocked_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'blocked from this chat';
  END IF;

  IF p_public_key IS NULL OR length(p_public_key) = 0 THEN
    RAISE EXCEPTION 'public key required';
  END IF;

  -- As with approval today: clear away any pending request, then become a
  -- member. The existing triggers on chat_members fire normally.
  DELETE FROM pending_chat_members
  WHERE chat_id = v_invite.chat_id AND user_id = auth.uid();

  INSERT INTO chat_members (chat_id, user_id, public_key)
  VALUES (v_invite.chat_id, auth.uid(), p_public_key);

  RETURN v_invite.chat_id;
END;
$$;

-- Table grant EXPLICITLY: newer Supabase setups no longer hand out default
-- grants on public (only TRUNCATE/REFERENCES/TRIGGER/MAINTAIN) — without this
-- line the RLS policy above would be without effect, because PostgREST already
-- fails on the missing SELECT grant. On old instances with a legacy default ACL
-- the line is redundant, but never wrong. SELECT only: writing goes exclusively
-- through the SECURITY DEFINER functions (owner rights).
GRANT SELECT ON public.chat_invites TO authenticated;

-- EXECUTE eng vergeben: nur eingeloggte Nutzer, nie anon/PUBLIC.
REVOKE EXECUTE ON FUNCTION public.create_chat_invite(uuid, uuid) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.revoke_chat_invite(uuid) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.redeem_chat_invite(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_chat_invite(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.revoke_chat_invite(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.redeem_chat_invite(uuid, text) TO authenticated;
