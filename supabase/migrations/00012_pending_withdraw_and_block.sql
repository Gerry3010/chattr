-- 00012_pending_withdraw_and_block.sql
--
-- Stage 7.4 (withdraw own join request) + 7.5 (block / anti-spam).
--
-- The Dart repository already exposes cancelRequest() (user deletes own pending
-- request) and blockMember() (admin sets blocked_at), but there was NO RLS policy
-- allowing a user to delete their own pending row — so withdrawal silently failed.
--
-- Blocking model (uses the existing pending_chat_members.blocked_at column rather
-- than a separate table): "reject & block" sets blocked_at instead of deleting, so
-- the (chat_id, user_id) row persists and the primary key prevents the blocked
-- user from inserting a fresh request (no repeated admin notifications = no spam).
--
-- This policy lets users withdraw their OWN request, but ONLY while it is not
-- blocked — otherwise a blocked user could delete the row and re-request, defeating
-- the block.

CREATE POLICY "Users can withdraw own pending request"
ON pending_chat_members FOR DELETE
TO authenticated
USING (auth.uid() = user_id AND blocked_at IS NULL);

COMMENT ON POLICY "Users can withdraw own pending request" ON pending_chat_members
IS 'Users may delete their own pending join request unless it has been blocked.';
