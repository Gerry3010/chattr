-- ============================================================================
-- 00055: Group chat avatars
-- ----------------------------------------------------------------------------
-- Groups get an optional avatar picture, mirroring user profile avatars
-- (00015): a plaintext image in a PUBLIC storage bucket — only message content
-- is E2E-encrypted; avatars are non-sensitive metadata by design.
--
-- Three parts:
--   1. chats.avatar_path column (the object path inside the bucket) — and, same
--      gotcha as 00023/00053, threaded through get_user_chats_with_metadata so
--      it actually reaches the client on refresh.
--   2. A dedicated `group-avatars` bucket. We can't reuse the `avatars` bucket:
--      its write RLS (00015) scopes writes to a folder named by the writer's
--      OWN uid (`<uid>/...`), whereas a group avatar lives under `<chatId>/...`
--      and must be writable by any ADMIN of that chat.
--   3. RLS: public read; write only for admins of the chat named by the path.
--
-- The chats.avatar_path column write itself is already covered by the existing
-- "Admins can manage chat properties" UPDATE policy (00005) — no change needed.
-- ============================================================================

-- 1. Column ------------------------------------------------------------------
ALTER TABLE chats ADD COLUMN IF NOT EXISTS avatar_path text;

COMMENT ON COLUMN chats.avatar_path IS 'Optional group avatar object path in the public group-avatars bucket (plaintext, non-sensitive metadata)';

-- 1b. Thread avatar_path through the chat-metadata RPC (built on 00053). The
-- DROP is required because adding a column changes the function's return type,
-- which CREATE OR REPLACE alone cannot do (same as 00023).
DROP FUNCTION IF EXISTS get_user_chats_with_metadata(uuid[]);

CREATE OR REPLACE FUNCTION get_user_chats_with_metadata(p_chat_ids uuid[] DEFAULT NULL::uuid[])
RETURNS TABLE(
  id uuid,
  created_at timestamptz,
  updated_at timestamptz,
  created_by uuid,
  name text,
  description text,
  avatar_path text,
  admins text[],
  is_group boolean,
  message_ttl_seconds integer,
  last_message_at timestamptz,
  unread_count bigint,
  is_mcp boolean,
  mcp_owner_id uuid
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN QUERY
  SELECT
    c.id,
    c.created_at,
    c.updated_at,
    c.created_by,
    c.name,
    c.description,
    c.avatar_path,
    c.admins::text[],
    c.is_group,
    c.message_ttl_seconds,
    (
      SELECT MAX(m.created_at)
      FROM messages m
      WHERE m.chat_id = c.id
        AND m.recipient_id = auth.uid()
    ) AS last_message_at,
    (
      -- Incoming messages newer than when I last opened this chat. Independent
      -- of read receipts: last_read_at is set by mark_chat_read() on open.
      SELECT COUNT(*)
      FROM messages m
      WHERE m.chat_id = c.id
        AND m.recipient_id = auth.uid()
        AND m.created_at > COALESCE(cm.last_read_at, '-infinity'::timestamptz)
    ) AS unread_count,
    c.is_mcp,
    c.mcp_owner_id
  FROM chats c
  INNER JOIN chat_members cm ON cm.chat_id = c.id
  WHERE cm.user_id = auth.uid()
    AND (p_chat_ids IS NULL OR c.id = ANY(p_chat_ids));
END;
$$;

-- 2. Bucket ------------------------------------------------------------------
INSERT INTO storage.buckets (id, name, public)
VALUES ('group-avatars', 'group-avatars', true)
ON CONFLICT (id) DO UPDATE SET public = true;

-- 3. RLS ---------------------------------------------------------------------
-- Public read (matches the public bucket + how user avatars work).
DROP POLICY IF EXISTS "Group avatars are publicly readable" ON storage.objects;
CREATE POLICY "Group avatars are publicly readable"
ON storage.objects FOR SELECT
USING (bucket_id = 'group-avatars');

-- Write (insert/update/delete) only for admins of the chat whose id is the
-- first path segment. We compare id AS TEXT (not a uuid cast) so a malformed
-- object name simply fails to match instead of raising a cast error.
--
-- IMPORTANT: the object name MUST be qualified as `objects.name`. `chats` has a
-- `name` column (the group name), so an unqualified `name` inside the subquery
-- binds to `chats.name` (inner scope wins) instead of the storage object's name
-- — which silently makes the predicate never match and denies every upload.
-- Caught on staging (would have failed 100% of group-avatar uploads on prod).
DROP POLICY IF EXISTS "Chat admins manage group avatar" ON storage.objects;
CREATE POLICY "Chat admins manage group avatar"
ON storage.objects FOR ALL
USING (
  bucket_id = 'group-avatars'
  AND EXISTS (
    SELECT 1 FROM chats c
    WHERE c.id::text = (storage.foldername(objects.name))[1]
      AND auth.uid() = ANY(c.admins)
  )
)
WITH CHECK (
  bucket_id = 'group-avatars'
  AND EXISTS (
    SELECT 1 FROM chats c
    WHERE c.id::text = (storage.foldername(objects.name))[1]
      AND auth.uid() = ANY(c.admins)
  )
);
