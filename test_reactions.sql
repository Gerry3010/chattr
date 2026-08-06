-- Test message reactions
-- Run these queries in Supabase SQL Editor to debug

-- 1. Check if table exists and has correct structure
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_name = 'message_reactions'
ORDER BY ordinal_position;

-- 2. Check current reactions (should be empty or have test data)
SELECT * FROM message_reactions LIMIT 10;

-- 3. Check RLS policies
SELECT schemaname, tablename, policyname, permissive, roles, cmd, qual, with_check
FROM pg_policies
WHERE tablename = 'message_reactions';

-- 4. Test the toggle function directly (replace with actual message_id)
-- Make sure you're authenticated as a user in a chat first
-- SELECT toggle_message_reaction('YOUR_MESSAGE_ID'::UUID, '😂');

-- 5. Check if you're in a chat (for debugging RLS)
-- SELECT 
--     cm.chat_id,
--     cm.user_id,
--     m.id as message_id
-- FROM chat_members cm
-- JOIN messages m ON m.chat_id = cm.chat_id
-- WHERE cm.user_id = auth.uid()
-- LIMIT 5;

-- 6. Try manual insert to test RLS (replace with actual values)
-- INSERT INTO message_reactions (message_id, user_id, reaction)
-- VALUES ('YOUR_MESSAGE_ID'::UUID, auth.uid(), '😂')
-- RETURNING *;
