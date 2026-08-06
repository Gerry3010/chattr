-- Migration: Chat Admins and Member Management
-- Adds admin functionality to chats with proper RLS policies

-- 1. Add admins array to chats table
ALTER TABLE chats 
ADD COLUMN admins UUID[] DEFAULT ARRAY[]::UUID[];

COMMENT ON COLUMN chats.admins IS 'Array of user IDs who are admins of this chat';

-- 2. Create function to initialize creator as admin
CREATE OR REPLACE FUNCTION set_creator_as_admin()
RETURNS TRIGGER AS $$
BEGIN
  -- Set the creator as the first admin
  NEW.admins := ARRAY[NEW.created_by];
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create trigger to set creator as admin on chat creation
DROP TRIGGER IF EXISTS chat_creator_admin_trigger ON chats;

CREATE TRIGGER chat_creator_admin_trigger
BEFORE INSERT ON chats
FOR EACH ROW
EXECUTE FUNCTION set_creator_as_admin();

-- 3. Create a function to handle admin reassignment when admin leaves
CREATE OR REPLACE FUNCTION reassign_admin_on_leave()
RETURNS TRIGGER AS $$
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
$$ LANGUAGE plpgsql;

-- Create trigger for admin reassignment
DROP TRIGGER IF EXISTS chat_member_leave_trigger ON chat_members;

CREATE TRIGGER chat_member_leave_trigger
AFTER DELETE ON chat_members
FOR EACH ROW
EXECUTE FUNCTION reassign_admin_on_leave();

-- 4. RLS Policies for chat_members table

-- Users can view members of chats they're in
DROP POLICY IF EXISTS "Users can view chat members" ON chat_members;

CREATE POLICY "Users can view chat members"
ON chat_members FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM chat_members cm
    WHERE cm.chat_id = chat_members.chat_id
    AND cm.user_id = auth.uid()
  )
);

-- Only admins can add new members to a chat
DROP POLICY IF EXISTS "Admins can add chat members" ON chat_members;

CREATE POLICY "Admins can add chat members"
ON chat_members FOR INSERT
WITH CHECK (
  EXISTS (
    SELECT 1 FROM chats
    WHERE chats.id = chat_members.chat_id
    AND auth.uid() = ANY(chats.admins)
  )
);

-- Only admins can remove members OR users can remove themselves
DROP POLICY IF EXISTS "Admins can remove members or users can leave" ON chat_members;

CREATE POLICY "Admins can remove members or users can leave"
ON chat_members FOR DELETE
USING (
  -- User is removing themselves
  chat_members.user_id = auth.uid()
  OR
  -- User is an admin of the chat
  EXISTS (
    SELECT 1 FROM chats
    WHERE chats.id = chat_members.chat_id
    AND auth.uid() = ANY(chats.admins)
  )
);

-- 5. RLS Policy for promoting/demoting admins (updating chats.admins)
-- Already covered by existing "Members can update chat member_keys" policy
-- We need to add a new policy specifically for admins array

DROP POLICY IF EXISTS "Admins can manage chat admins" ON chats;

CREATE POLICY "Admins can manage chat admins"
ON chats FOR UPDATE
USING (
  auth.uid() = ANY(chats.admins)
)
WITH CHECK (
  auth.uid() = ANY(chats.admins)
);

-- 6. Create helper function to check if user is admin
CREATE OR REPLACE FUNCTION is_chat_admin(chat_id_param UUID, user_id_param UUID)
RETURNS BOOLEAN AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM chats
    WHERE id = chat_id_param
    AND user_id_param = ANY(admins)
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION is_chat_admin IS 'Check if a user is an admin of a specific chat';
