-- ============================================================================
-- 00031: Block users (1:1 scope, DB-enforced)
-- ----------------------------------------------------------------------------
-- A user can block another user. Effects (v1, direct chats only — shared
-- group chats are deliberately unaffected):
--   * Neither side can create a new 1:1 chat with the other (the QR-rescan
--     loophole): the chat_members INSERT that would join the blocked pair
--     into a direct chat is rejected.
--   * Neither side can send messages in a still-existing shared 1:1 chat.
--   * The blocked party gets no signal — their inserts just fail.
-- Only the blocker can see and manage their own block list. Enforcement
-- checks both directions via a SECURITY DEFINER helper (the blocked party
-- can't read the table, but their inserts must still be rejected).
-- ============================================================================

CREATE TABLE blocked_users (
  blocker_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  blocked_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (blocker_id, blocked_id),
  CHECK (blocker_id != blocked_id)
);

COMMENT ON TABLE blocked_users IS
  'User-level blocks. Enforced for direct (1:1) chats via triggers on chat_members and messages.';

ALTER TABLE blocked_users ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users manage their own blocks"
ON blocked_users FOR ALL
TO authenticated
USING (blocker_id = auth.uid())
WITH CHECK (blocker_id = auth.uid());

-- Helper: is there a block in either direction between a and b?
-- SECURITY DEFINER because enforcement must also see blocks the acting user
-- isn't allowed to read (the blocked party's inserts must fail too).
CREATE OR REPLACE FUNCTION is_blocked_pair(a UUID, b UUID)
RETURNS BOOLEAN
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE sql
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1 FROM blocked_users
    WHERE (blocker_id = a AND blocked_id = b)
       OR (blocker_id = b AND blocked_id = a)
  );
$$;

-- Enforcement 1: joining a direct chat is rejected when the new member forms
-- a blocked pair with any existing member. This is the choke point for the
-- QR-rescan flow (create chat → insert member A → insert member B fails →
-- the whole creation transaction rolls back client-side or leaves an empty
-- chat that reassign_admin_on_leave-style cleanup removes on leave).
CREATE OR REPLACE FUNCTION guard_blocked_direct_membership()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql
AS $$
DECLARE
  v_is_group BOOLEAN;
BEGIN
  SELECT is_group INTO v_is_group FROM chats WHERE id = NEW.chat_id;
  IF v_is_group THEN
    RETURN NEW;
  END IF;

  IF EXISTS (
    SELECT 1 FROM chat_members m
    WHERE m.chat_id = NEW.chat_id
      AND m.user_id != NEW.user_id
      AND is_blocked_pair(NEW.user_id, m.user_id)
  ) THEN
    RAISE EXCEPTION 'blocked: cannot join a direct chat with a blocked user'
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS guard_blocked_direct_membership_trigger ON chat_members;
CREATE TRIGGER guard_blocked_direct_membership_trigger
  BEFORE INSERT ON chat_members
  FOR EACH ROW
  EXECUTE FUNCTION guard_blocked_direct_membership();

-- Enforcement 2: no messages between a blocked pair in direct chats (covers
-- a still-shared 1:1 that neither party has left).
CREATE OR REPLACE FUNCTION guard_blocked_direct_message()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql
AS $$
DECLARE
  v_is_group BOOLEAN;
BEGIN
  IF NEW.sender_id IS NULL OR NEW.recipient_id IS NULL THEN
    RETURN NEW; -- system messages are exempt
  END IF;

  SELECT is_group INTO v_is_group FROM chats WHERE id = NEW.chat_id;
  IF v_is_group THEN
    RETURN NEW;
  END IF;

  IF is_blocked_pair(NEW.sender_id, NEW.recipient_id) THEN
    RAISE EXCEPTION 'blocked: cannot message a blocked user'
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS guard_blocked_direct_message_trigger ON messages;
CREATE TRIGGER guard_blocked_direct_message_trigger
  BEFORE INSERT ON messages
  FOR EACH ROW
  EXECUTE FUNCTION guard_blocked_direct_message();
