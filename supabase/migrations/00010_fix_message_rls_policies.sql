-- 00010_fix_message_rls_policies.sql
--
-- Stage 1.3: Remove the over-permissive / duplicate RLS policies on `messages`.
--
-- Problem: two SELECT policies and two INSERT policies coexisted. PostgreSQL ORs
-- permissive policies together, so the loose variants nullified the strict ones:
--   * SELECT "Users can read messages in their chats" allowed
--       recipient_id = auth.uid() OR sender_id = auth.uid()
--     which defeated the strict "Users can read their encrypted messages"
--     (recipient_id = auth.uid()) — letting a sender read every per-recipient row.
--   * INSERT "Users can insert messages in their chats" did not require the
--     recipient to actually be a chat member, unlike the stricter
--     "Users can insert messages for all chat members".
--
-- Fix: drop the loose SELECT and the redundant INSERT; keep only the strict ones.

-- Drop the over-permissive SELECT policy (recipient-only remains).
DROP POLICY IF EXISTS "Users can read messages in their chats" ON messages;

-- Drop the redundant/looser INSERT policy (the per-recipient-member one remains).
DROP POLICY IF EXISTS "Users can insert messages in their chats" ON messages;

-- Sanity: ensure the strict policies still exist (no-op if already present).
-- Strict SELECT: recipients only.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'messages'
      AND policyname = 'Users can read their encrypted messages'
  ) THEN
    CREATE POLICY "Users can read their encrypted messages"
    ON messages FOR SELECT
    USING (recipient_id = auth.uid());
  END IF;
END$$;

-- Strict INSERT: sender is the caller AND recipient is a member of the chat.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'messages'
      AND policyname = 'Users can insert messages for all chat members'
  ) THEN
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
  END IF;
END$$;
