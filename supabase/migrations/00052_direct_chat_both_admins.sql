-- 00052: In a 1:1 (direct, non-MCP) chat, BOTH participants are admins.
--
-- Today only the CREATOR of a chat becomes admin: set_creator_as_admin()
-- (00002) fires BEFORE INSERT on `chats` and stamps admins := ARRAY[auth.uid()],
-- before any chat_members rows exist, so it can only ever capture the creator.
-- For a 1:1 that means the QR scanner is the sole admin and the scanned peer is
-- a plain member — they can't rename / set the disappearing-timer / delete the
-- chat (those are RLS-gated on auth.uid() = ANY(chats.admins)). In a 1:1 there
-- is no hierarchy, so both sides should have those powers.
--
-- Scope is strictly `NOT is_group AND NOT is_mcp`:
--   * groups keep their creator/approval admin model untouched,
--   * MCP agent chats keep the owner-sole-admin rule (00044); they are is_group
--     = true anyway (bind_mcp_chat), so the is_mcp guard is belt-and-suspenders.
--
-- guard_direct_chat_admins() (00030) rejects ANY admins change on a non-group
-- chat unless the transaction-local GUC `chattr.admin_reassign` = 'on'. Both the
-- trigger and the backfill below perform that handshake (clients can't set GUCs
-- through PostgREST, so this stays unreachable from the API).
--
-- No spurious "promoted to admin" system message: notify_admin_promotion (00033)
-- early-returns for non-group chats.
--
-- No Flutter change needed: isAdmin() already reads chats.admins, and the
-- admins change propagates live via notify_chat_update -> ChatUpdateEvent ->
-- refreshChats.

-- ============================================================================
-- Part 1: whenever a member is added to a direct (non-MCP) chat, make them admin
-- ============================================================================
CREATE OR REPLACE FUNCTION add_direct_chat_member_as_admin()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql
AS $$
DECLARE
  chat_record RECORD;
BEGIN
  SELECT is_group, is_mcp, admins
    INTO chat_record
    FROM chats
    WHERE id = NEW.chat_id;

  -- Only direct, non-MCP chats. Groups + MCP owner-admin semantics untouched.
  IF chat_record IS NULL OR chat_record.is_group OR chat_record.is_mcp THEN
    RETURN NEW;
  END IF;

  -- Already an admin (e.g. the creator's own membership row) → nothing to do.
  IF NEW.user_id = ANY(COALESCE(chat_record.admins, ARRAY[]::uuid[])) THEN
    RETURN NEW;
  END IF;

  -- Announce to guard_direct_chat_admins (00030) that this is a legitimate,
  -- server-side admins change (transaction-local; not reachable via PostgREST).
  PERFORM set_config('chattr.admin_reassign', 'on', true);

  UPDATE chats
    SET admins = array_append(COALESCE(admins, ARRAY[]::uuid[]), NEW.user_id)
    WHERE id = NEW.chat_id;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS add_direct_chat_member_as_admin_trigger ON chat_members;
CREATE TRIGGER add_direct_chat_member_as_admin_trigger
  AFTER INSERT ON chat_members
  FOR EACH ROW
  EXECUTE FUNCTION add_direct_chat_member_as_admin();

-- ============================================================================
-- Part 2: backfill existing direct (non-MCP) chats so both current members are
-- admins. Idempotent — only touches rows whose admins set differs.
-- ============================================================================
DO $$
BEGIN
  PERFORM set_config('chattr.admin_reassign', 'on', true);

  UPDATE chats c
    SET admins = sub.member_ids
    FROM (
      SELECT chat_id, array_agg(user_id ORDER BY user_id) AS member_ids
      FROM chat_members
      GROUP BY chat_id
    ) sub
    WHERE c.id = sub.chat_id
      AND NOT c.is_group
      AND NOT c.is_mcp
      AND (
        SELECT array_agg(a ORDER BY a) FROM unnest(c.admins) a
      ) IS DISTINCT FROM sub.member_ids;
END $$;

-- ============================================================================
-- Part 3: keep a 1:1 locked to its two participants.
--
-- Making the peer an admin means BOTH sides satisfy "Admins can add members".
-- Without a guard either party could then add a third member and quietly turn a
-- 1:1 into a group. But that same policy is ALSO how createChat inserts the two
-- members at creation time (the creator is admin via set_creator_as_admin, and
-- there is no separate self-insert policy). So we cannot simply scope it to
-- groups — that would break 1:1 creation.
--
-- Instead: an admin may INSERT a member when the chat is a group OR while the
-- direct chat still has fewer than 2 members (i.e. it is being created). The two
-- creation rows are inserted in a single statement whose WITH CHECK sees the
-- pre-statement count (0 < 2 → both pass); afterwards the 1:1 has 2 members, so
-- any later add is rejected (2 < 2 is false).
-- ============================================================================
DROP POLICY IF EXISTS "Admins can add members" ON chat_members;
CREATE POLICY "Admins can add members"
ON chat_members FOR INSERT
TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1 FROM chats
    WHERE chats.id = chat_id
      AND auth.uid() = ANY(chats.admins)
      AND (
        chats.is_group
        OR (
          SELECT count(*) FROM chat_members cm WHERE cm.chat_id = chats.id
        ) < 2
      )
  )
);

COMMENT ON FUNCTION add_direct_chat_member_as_admin IS
  'Adds each member of a direct (non-group, non-MCP) chat to chats.admins so both 1:1 participants are admins (#151). Uses the chattr.admin_reassign GUC handshake to pass guard_direct_chat_admins (00030).';
