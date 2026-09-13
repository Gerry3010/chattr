-- SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
-- SPDX-License-Identifier: AGPL-3.0-or-later

-- ============================================================================
-- 00071: Redeemed invitations withdraw themselves
-- ----------------------------------------------------------------------------
-- An invitation (00069) is valid ONLY in the target chat: it can be redeemed
-- exclusively by a member of `target_chat_id`. So as soon as everybody from the
-- target chat is in the group, there is nobody left who could still use the
-- token — the invitation is spent. Until now it nevertheless stayed under
-- "active invitations" forever, offering to revoke access that had long been
-- redeemed. With a 1:1 target chat that means: **every** invitation, the moment
-- the invited person joins.
--
-- 1.18.2 already sweeps that in the client. But the client can only do it for
-- target chats it sees itself — if ANOTHER admin invites into a chat we are not
-- in, RLS shows us no member rows, and "no rows" must never be read as
-- "everybody is in" (otherwise one would withdraw a living invitation behind
-- its back). That is exactly the case Gerry noticed: SeB invited David through
-- his 1:1 with David, David joined, the invitation stayed.
--
-- The server sees both memberships. So the rule belongs here — at the place
-- where the membership COMES INTO BEING, not at the one that displays it.
--
-- What changes is exclusively the body of `redeem_chat_invite`; signature,
-- grants and every existing check remain word for word. New is only the block
-- at the very end.
--
-- Deliberately NOT built: tying it to the invitation message's life cycle ("the
-- invitation dies when the card is deleted"). That would need a new column
-- token ↔ message_id for a rarer case; the state here covers Gerry's
-- observation completely.
-- ============================================================================

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
    -- Sweep here too: whoever taps the card a second time is the best occasion
    -- to check whether everybody is in by now.
    PERFORM public.retire_invite_if_fulfilled(p_token);
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

  -- NEW: if this invitation has thereby served its purpose, it withdraws
  -- itself. Deliberately AFTER the INSERT — one's own fresh membership counts.
  PERFORM public.retire_invite_if_fulfilled(p_token);

  RETURN v_invite.chat_id;
END;
$$;

-- ----------------------------------------------------------------------------
-- retire_invite_if_fulfilled: sets `revoked_at` when nobody in the target chat
-- is missing any more. A function of its own so the rule is formulated ONCE and
-- can be called from both return paths above.
-- ----------------------------------------------------------------------------
-- `revoked_by` stays NULL: it was not an admin's decision but consumption.
-- Whoever reads the row later should be able to tell the two cases apart.
--
-- SECURITY DEFINER like the other three — the caller has just joined and is
-- typically NOT an admin of the group, so they may neither read nor write
-- `chat_invites`. That is also why EXECUTE is not granted to `authenticated`
-- here: the function is a building block of `redeem_chat_invite`, not an entry
-- point of its own. Without that restriction anybody logged in could try
-- guessed tokens to see which of them are due.
CREATE OR REPLACE FUNCTION public.retire_invite_if_fulfilled(p_token UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  UPDATE chat_invites ci
  SET revoked_at = NOW()
  WHERE ci.token = p_token
    AND ci.revoked_at IS NULL
    -- Nobody in the target chat who is not already in the group.
    AND NOT EXISTS (
      SELECT 1
      FROM chat_members t
      WHERE t.chat_id = ci.target_chat_id
        AND NOT EXISTS (
          SELECT 1 FROM chat_members g
          WHERE g.chat_id = ci.chat_id AND g.user_id = t.user_id
        )
    )
    -- An EMPTY target chat formally satisfies "nobody is missing" but says
    -- nothing. Without this line an invitation into a chat whose members are
    -- all leaving would be withdrawn silently.
    AND EXISTS (
      SELECT 1 FROM chat_members t2 WHERE t2.chat_id = ci.target_chat_id
    );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.retire_invite_if_fulfilled(uuid)
  FROM PUBLIC, anon, authenticated;

-- Clean up the stock: everything that is long spent by this rule is withdrawn
-- once — otherwise precisely Gerry's David invitation would stay, because it IS
-- already redeemed and `redeem` never runs for it again.
UPDATE public.chat_invites ci
SET revoked_at = NOW()
WHERE ci.revoked_at IS NULL
  AND NOT EXISTS (
    SELECT 1 FROM public.chat_members t
    WHERE t.chat_id = ci.target_chat_id
      AND NOT EXISTS (
        SELECT 1 FROM public.chat_members g
        WHERE g.chat_id = ci.chat_id AND g.user_id = t.user_id
      )
  )
  AND EXISTS (
    SELECT 1 FROM public.chat_members t2 WHERE t2.chat_id = ci.target_chat_id
  );
