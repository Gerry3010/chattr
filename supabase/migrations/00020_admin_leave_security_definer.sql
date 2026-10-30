-- Fix: admins (incl. the sole admin) could not leave a group chat.
--
-- `reassign_admin_on_leave()` (00002_functions.sql) is the AFTER DELETE trigger
-- on `chat_members`. Unlike every sibling function in 00002 it was created
-- WITHOUT `SECURITY DEFINER`, so its `chats` mutations ran under the *leaving
-- user's* RLS. The `chats` UPDATE policy is
--     USING (auth.uid() = ANY(admins))  WITH CHECK (auth.uid() = ANY(admins))
-- so the very first statement — removing the leaving user from `admins` —
-- produces a NEW row in which auth.uid() is no longer an admin, the WITH CHECK
-- fails, the UPDATE raises, and the whole leave transaction (including the
-- already-permitted chat_members self-delete) rolls back. Net effect: a
-- non-admin could leave, an admin could not (chat stayed, no error surfaced).
--
-- Make the function SECURITY DEFINER (matching its siblings) so the admin
-- reassignment / orphan-chat deletion run with the owner's privileges and
-- bypass RLS. Pin search_path per the 00017/00018 convention. Logic is
-- unchanged — it was already correct, it just couldn't execute.

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
