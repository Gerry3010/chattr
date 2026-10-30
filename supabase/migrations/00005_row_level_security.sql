-- ============================================================================
-- Row Level Security (RLS) Policies
-- ============================================================================
-- This migration enables RLS and creates all security policies for tables
-- ============================================================================

-- ============================================================================
-- PART 1: Enable RLS on All Tables
-- ============================================================================

ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE chats ENABLE ROW LEVEL SECURITY;
ALTER TABLE chat_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE pending_chat_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE device_tokens ENABLE ROW LEVEL SECURITY;

-- ============================================================================
-- PART 2: Profiles Table Policies
-- ============================================================================

-- All authenticated users can view profiles
CREATE POLICY "Authenticated users can view profiles"
ON profiles FOR SELECT
USING (auth.uid() IS NOT NULL);

-- Users can create their own profile
CREATE POLICY "Users can create their own profile"
ON profiles FOR INSERT
WITH CHECK (auth.uid() = id);

-- Users can update their own profile
CREATE POLICY "Users can update their own profile"
ON profiles FOR UPDATE
USING (auth.uid() = id)
WITH CHECK (auth.uid() = id);

-- Users can delete their own profile
CREATE POLICY "Users can delete their own profile"
ON profiles FOR DELETE
USING (auth.uid() = id);

-- ============================================================================
-- PART 3: Chats Table Policies
-- ============================================================================

-- Authenticated users can create chats
CREATE POLICY "Authenticated users can create chats"
ON chats FOR INSERT
WITH CHECK (auth.uid() IS NOT NULL);

-- Members and admins can view their chats
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

-- Admins can update chat properties
CREATE POLICY "Admins can manage chat properties"
ON chats FOR UPDATE
USING (auth.uid() = ANY(admins))
WITH CHECK (auth.uid() = ANY(admins));

COMMENT ON POLICY "Admins can manage chat properties" ON chats IS 'Admins can update chat name, admins array, and other admin-controlled properties';

-- Admins can delete chats
CREATE POLICY "Admins can delete chats"
ON chats FOR DELETE
USING (auth.uid() = ANY(admins));

-- ============================================================================
-- PART 4: Chat Members Table Policies
-- ============================================================================

-- Members can view all members of chats they belong to
CREATE POLICY "Members can view chat members"
ON chat_members FOR SELECT
TO authenticated
USING (is_chat_member(chat_id, auth.uid()));

COMMENT ON POLICY "Members can view chat members" ON chat_members IS 'Members can view all members of chats they belong to (uses helper function to avoid recursion)';

-- Only admins can insert new members (after approval)
CREATE POLICY "Admins can add members"
ON chat_members FOR INSERT
TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1 FROM chats
    WHERE chats.id = chat_id
    AND auth.uid() = ANY(chats.admins)
  )
);

-- Admins can update any member
CREATE POLICY "Admins can update members"
ON chat_members FOR UPDATE
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM chats
    WHERE chats.id = chat_members.chat_id
    AND auth.uid() = ANY(chats.admins)
  )
);

-- Members can update their own record (e.g., public key)
CREATE POLICY "Members can update own record"
ON chat_members FOR UPDATE
TO authenticated
USING (auth.uid() = user_id);

-- Admins can remove any member
CREATE POLICY "Admins can remove members"
ON chat_members FOR DELETE
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM chats
    WHERE chats.id = chat_members.chat_id
    AND auth.uid() = ANY(chats.admins)
  )
);

-- Members can remove themselves (leave chat)
CREATE POLICY "Members can leave chat"
ON chat_members FOR DELETE
TO authenticated
USING (auth.uid() = user_id);

-- ============================================================================
-- PART 5: Pending Chat Members Table Policies
-- ============================================================================

-- Users can insert their own pending membership requests
CREATE POLICY "Users can request to join chats"
ON pending_chat_members FOR INSERT
TO authenticated
WITH CHECK (auth.uid() = user_id);

-- Users can view their own pending requests
CREATE POLICY "Users can view own pending requests"
ON pending_chat_members FOR SELECT
TO authenticated
USING (auth.uid() = user_id);

-- Chat admins can view all pending requests for their chats
CREATE POLICY "Admins can view pending requests"
ON pending_chat_members FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM chats
    WHERE chats.id = pending_chat_members.chat_id
    AND auth.uid() = ANY(chats.admins)
  )
);

-- Chat admins can update pending requests (e.g., block)
CREATE POLICY "Admins can update pending requests"
ON pending_chat_members FOR UPDATE
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM chats
    WHERE chats.id = pending_chat_members.chat_id
    AND auth.uid() = ANY(chats.admins)
  )
);

-- Chat admins can delete pending requests (approve or reject)
CREATE POLICY "Admins can delete pending requests"
ON pending_chat_members FOR DELETE
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM chats
    WHERE chats.id = pending_chat_members.chat_id
    AND auth.uid() = ANY(chats.admins)
  )
);

-- ============================================================================
-- PART 6: Messages Table Policies
-- ============================================================================

-- Users can read messages where they are the recipient or sender
CREATE POLICY "Users can read messages in their chats"
ON messages FOR SELECT
USING (
  recipient_id = auth.uid()
  OR sender_id = auth.uid()
);

-- Alternative stricter policy: Users can only read their encrypted messages
CREATE POLICY "Users can read their encrypted messages"
ON messages FOR SELECT
USING (recipient_id = auth.uid());

-- Users can insert messages in chats they belong to
CREATE POLICY "Users can insert messages in their chats"
ON messages FOR INSERT
WITH CHECK (
  sender_id = auth.uid()
  AND EXISTS (
    SELECT 1 FROM chat_members
    WHERE chat_members.chat_id = messages.chat_id
    AND chat_members.user_id = auth.uid()
  )
);

-- Users can insert messages for all chat members (creates encrypted copies)
CREATE POLICY "Users can insert messages for all chat members"
ON messages FOR INSERT
WITH CHECK (
  sender_id = auth.uid()
  AND EXISTS (
    SELECT 1 FROM chat_members
    WHERE chat_members.chat_id = messages.chat_id
    AND chat_members.user_id = messages.recipient_id
  )
);

-- Only senders can update their messages (e.g., edit content)
-- Recipients use mark_message_received() and mark_message_read() functions instead
CREATE POLICY "Senders can update their messages"
ON messages FOR UPDATE
USING (sender_id = auth.uid())
WITH CHECK (sender_id = auth.uid());

COMMENT ON POLICY "Senders can update their messages" ON messages IS 'Only senders can update message content. Recipients must use mark_message_received() and mark_message_read() functions.';

-- Senders can delete unread messages
CREATE POLICY "Senders can delete unread messages"
ON messages FOR DELETE
USING (
  sender_id = auth.uid()
  AND read_at IS NULL
);

COMMENT ON POLICY "Senders can delete unread messages" ON messages IS 'Senders can delete their messages only if they have not been read yet';

-- ============================================================================
-- PART 7: Device Tokens Table Policies
-- ============================================================================

-- Users can manage their own device tokens
CREATE POLICY "Users can manage own tokens"
ON device_tokens
USING (auth.uid() = user_id);
