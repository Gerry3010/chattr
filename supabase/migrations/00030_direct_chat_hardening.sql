-- ============================================================================
-- 00030: Direct-chat (1:1) hardening — no promote/demote/kick
-- ----------------------------------------------------------------------------
-- Member management is a group concept. In a 1:1 chat the QR-scanning creator
-- is the sole admin (set_creator_as_admin) and could promote/demote/remove
-- the other party via direct table writes — the UI now hides those actions,
-- but RLS never checked is_group, so the API allowed them regardless.
--
-- Two enforcement pieces:
--  1. A BEFORE UPDATE trigger on chats rejects changes to `admins` on
--     non-group chats. The legitimate exception is reassign_admin_on_leave
--     (00020): when a 1:1 admin leaves, the remaining member must inherit
--     admin (they need it to delete the orphaned chat). That function is
--     redefined to announce itself via a transaction-local GUC the guard
--     trusts. Clients can't set GUCs through PostgREST, so the handshake is
--     not reachable from the API.
--  2. The chat_members DELETE policy for admins is scoped to group chats
--     (self-leave policy "Members can leave chat" is untouched).
-- ============================================================================

-- 1a. Guard trigger on chats.admins for direct chats.
CREATE OR REPLACE FUNCTION guard_direct_chat_admins()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE plpgsql
AS $$
BEGIN
  IF NOT NEW.is_group
     AND NEW.admins IS DISTINCT FROM OLD.admins
     AND current_setting('chattr.admin_reassign', true) IS DISTINCT FROM 'on'
  THEN
    RAISE EXCEPTION 'admin changes are not allowed in direct chats'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS guard_direct_chat_admins_trigger ON chats;
CREATE TRIGGER guard_direct_chat_admins_trigger
  BEFORE UPDATE ON chats
  FOR EACH ROW
  EXECUTE FUNCTION guard_direct_chat_admins();

-- 1b. Same function as 00020, plus the GUC handshake so the leave flow's
--     admin reassignment passes the new guard (also in 1:1 chats).
CREATE OR REPLACE FUNCTION reassign_admin_on_leave()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  chat_record RECORD;
  remaining_member UUID;
BEGIN
  -- Get the chat
  SELECT * INTO chat_record FROM chats WHERE id = OLD.chat_id;

  -- Check if the leaving user was an admin
  IF OLD.user_id = ANY(chat_record.admins) THEN
    -- Announce the system reassignment to guard_direct_chat_admins
    -- (transaction-local; PostgREST clients cannot set GUCs).
    PERFORM set_config('chattr.admin_reassign', 'on', true);

    -- Remove the leaving user from the admins array
    UPDATE chats
    SET admins = array_remove(admins, OLD.user_id)
    WHERE id = OLD.chat_id;

    -- Check if there are no admins left
    IF (SELECT array_length(array_remove(chat_record.admins, OLD.user_id), 1) IS NULL
        OR array_length(array_remove(chat_record.admins, OLD.user_id), 1) = 0) THEN
      -- Select a random remaining member to be admin
      SELECT user_id INTO remaining_member
      FROM chat_members
      WHERE chat_id = OLD.chat_id
      AND user_id != OLD.user_id
      ORDER BY RANDOM()
      LIMIT 1;

      -- If there's a remaining member, make them admin
      IF remaining_member IS NOT NULL THEN
        UPDATE chats
        SET admins = array_append(admins, remaining_member)
        WHERE id = OLD.chat_id;
      -- If there are no remaining members, delete the chat
      ELSE
        DELETE FROM chats WHERE id = OLD.chat_id;
      END IF;
    END IF;
  END IF;

  RETURN OLD;
END;
$$;

-- 2. Admin kick is group-only (self-leave stays a separate policy).
DROP POLICY IF EXISTS "Admins can remove members" ON chat_members;
CREATE POLICY "Admins can remove members"
ON chat_members FOR DELETE
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM chats
    WHERE chats.id = chat_members.chat_id
    AND chats.is_group
    AND auth.uid() = ANY(chats.admins)
  )
);

COMMENT ON POLICY "Admins can remove members" ON chat_members IS
  'Admins can remove other members — group chats only; 1:1 chats have no member management.';
COMMENT ON FUNCTION guard_direct_chat_admins IS
  'Rejects admin-array changes on direct (non-group) chats except the reassign-on-leave flow.';
