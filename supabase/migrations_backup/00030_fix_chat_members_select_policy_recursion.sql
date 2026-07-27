-- Fix infinite recursion in chat_members SELECT policy
-- The policy was checking chat_members to determine if user can view chat_members
-- This creates a circular reference causing infinite recursion

-- Drop the problematic policy
DROP POLICY IF EXISTS "Members can view chat members" ON chat_members;

-- Create a helper function with SECURITY DEFINER to bypass RLS
CREATE OR REPLACE FUNCTION is_chat_member(p_chat_id UUID, p_user_id UUID)
RETURNS BOOLEAN
SECURITY DEFINER
AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM chat_members
    WHERE chat_id = p_chat_id
    AND user_id = p_user_id
  );
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION is_chat_member IS 'Check if a user is a member of a chat (bypasses RLS to avoid recursion)';

-- Recreate the SELECT policy using the helper function
CREATE POLICY "Members can view chat members"
ON chat_members
FOR SELECT
TO authenticated
USING (
  is_chat_member(chat_members.chat_id, auth.uid())
);

COMMENT ON POLICY "Members can view chat members" ON chat_members IS 'Members can view all members of chats they belong to (uses helper function to avoid recursion)';
