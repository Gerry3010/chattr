-- Enable RLS on chat_members and clean up duplicate policies

-- Enable RLS on chat_members table (should have been enabled from the start)
ALTER TABLE chat_members ENABLE ROW LEVEL SECURITY;

-- Drop old duplicate policies from earlier migrations
DROP POLICY IF EXISTS "Admins can add chat members" ON chat_members;
DROP POLICY IF EXISTS "Admins can remove members or users can leave" ON chat_members;
DROP POLICY IF EXISTS "Admins can update chat members" ON chat_members;
DROP POLICY IF EXISTS "Users can view chat members" ON chat_members;

-- Drop the duplicate trigger (keep the one from migration 00027)
DROP TRIGGER IF EXISTS on_membership_change ON chat_members;

COMMENT ON TABLE chat_members IS 'Members of chats who have been approved by admins';
COMMENT ON TABLE pending_chat_members IS 'Pending membership requests awaiting admin approval';
