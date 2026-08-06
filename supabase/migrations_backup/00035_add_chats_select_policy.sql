-- Add SELECT policy for chats table
-- Members can view chats they belong to

CREATE POLICY "Members can view their chats"
ON chats FOR SELECT
TO authenticated
USING (
  -- User is a member of the chat
  EXISTS (
    SELECT 1 FROM chat_members
    WHERE chat_members.chat_id = chats.id
    AND chat_members.user_id = auth.uid()
  )
  -- OR user is an admin of the chat
  OR auth.uid() = ANY(chats.admins)
);

COMMENT ON POLICY "Members can view their chats" ON chats IS 'Members can view chats they belong to';
