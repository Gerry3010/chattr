-- 00021: messages INSERT must also require the SENDER to be a chat member.
--
-- The surviving INSERT policy (00005, kept by 00010) checks only
--   sender_id = auth.uid()  AND  recipient is a member of the chat.
-- It never checks that the SENDER belongs to the chat — any authenticated
-- user who knows a chat_id and a member's user_id can insert rows into a
-- foreign chat. The junk ciphertext never decrypts, but each insert fires
-- notify_members_new_message (00003): push notification + realtime event +
-- phantom unread count for the victim — a spam/DoS vector.
--
-- Replace the policy with one that additionally requires sender membership.

DROP POLICY IF EXISTS "Users can insert messages for all chat members" ON messages;

CREATE POLICY "Users can insert messages for all chat members"
ON messages FOR INSERT
WITH CHECK (
  sender_id = auth.uid()
  AND EXISTS (
    SELECT 1 FROM chat_members
    WHERE chat_members.chat_id = messages.chat_id
      AND chat_members.user_id = messages.recipient_id
  )
  AND EXISTS (
    SELECT 1 FROM chat_members
    WHERE chat_members.chat_id = messages.chat_id
      AND chat_members.user_id = auth.uid()
  )
);
