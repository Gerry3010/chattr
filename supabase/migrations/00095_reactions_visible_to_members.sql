-- SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
-- SPDX-License-Identifier: AGPL-3.0-or-later
--
-- 00095: a reaction on your own message can be taken back again.
--
-- The policies on message_reactions (00007) decide membership by reading
-- `messages`, and that read runs under the caller's own RLS. A user may only
-- read message rows addressed TO them ("Users can read their encrypted
-- messages": recipient_id = auth.uid()); the sender has no row of their own.
-- So a reaction on a message you sent was invisible to you, and the app's
-- explicit `DELETE ... WHERE message_id = ... AND user_id = ... AND reaction =
-- ...` (since 2026-08-13, chosen over the toggle RPC so a second device could
-- not turn a removal into an insert) matched no row, without any error. The
-- summary RPC runs as definer and kept showing it. Gerry's iPhone and Galaxy,
-- 2026-10-30; reacting to one's own messages became common with the
-- double-tap reaction (CHAT-15).
--
-- Membership is now asked through a definer function that answers yes or no
-- for the CALLER only, so it reveals nothing about chats one is not in. The
-- DELETE policy itself (own rows only) is unchanged; it simply finds the row
-- again. Old apps in the field are fixed as well, nothing changes client-side.

CREATE OR REPLACE FUNCTION public.is_member_of_message_chat(p_message_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM messages m
    JOIN chat_members cm ON cm.chat_id = m.chat_id
    WHERE m.id = p_message_id
      AND cm.user_id = auth.uid()
  );
$$;

REVOKE ALL ON FUNCTION public.is_member_of_message_chat(UUID) FROM PUBLIC, anon;
-- Policies run with the caller's privileges, so the caller needs EXECUTE.
GRANT EXECUTE ON FUNCTION public.is_member_of_message_chat(UUID) TO authenticated;

COMMENT ON FUNCTION public.is_member_of_message_chat(UUID) IS
  'True when the CALLER is a member of the chat a message belongs to. For the '
  'message_reactions policies: reading messages directly is limited to rows '
  'addressed to the caller, which hid reactions on the caller''s own messages.';

DROP POLICY IF EXISTS "Users can view reactions in their chats" ON message_reactions;
CREATE POLICY "Users can view reactions in their chats"
  ON message_reactions
  FOR SELECT
  USING (public.is_member_of_message_chat(message_id));

DROP POLICY IF EXISTS "Users can add reactions in their chats" ON message_reactions;
CREATE POLICY "Users can add reactions in their chats"
  ON message_reactions
  FOR INSERT
  WITH CHECK (
    user_id = auth.uid()
    AND public.is_member_of_message_chat(message_id)
  );
