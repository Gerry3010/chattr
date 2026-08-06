-- SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
-- SPDX-License-Identifier: AGPL-3.0-or-later

-- Unread badge decoupled from the read RECEIPT.
--
-- The chat-list unread badge came from get_user_chats_with_metadata counting
-- messages with `read_at IS NULL`. But `read_at` is only ever set by
-- mark_message_read(), which the client SKIPS entirely when the user has read
-- receipts OFF (reciprocal privacy — the sender must not learn the message was
-- read). Result: a receipts-off user's messages stay `read_at IS NULL` forever,
-- so the badge phantom-counts them and reappears on every app start (the local
-- reset is in-memory only, re-derived from this RPC on load).
--
-- We can't just set read_at server-side when receipts are off — the sender can
-- query it (get_sent_message_status) and would learn the read status. So this
-- adds a PRIVATE per-member "opened this chat" marker (chat_members.last_read_at)
-- that the sender can never see (RLS exposes only your own membership row), and
-- bases the unread count on it instead of the receipt.

-- 1. Private per-member read marker. Existing rows are backfilled to now() so
--    the deploy doesn't retroactively flag every past message as unread.
ALTER TABLE chat_members
  ADD COLUMN IF NOT EXISTS last_read_at timestamptz;

UPDATE chat_members
  SET last_read_at = now()
  WHERE last_read_at IS NULL;

-- 2. Mark the whole chat read for the CURRENT user. Private: no receipt, no
--    broadcast, only touches the caller's own membership row — so it works the
--    same whether or not read receipts are enabled.
CREATE OR REPLACE FUNCTION mark_chat_read(p_chat_id uuid)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  UPDATE chat_members
  SET last_read_at = now()
  WHERE chat_id = p_chat_id
    AND user_id = auth.uid();
$$;

REVOKE ALL ON FUNCTION mark_chat_read(uuid) FROM public;
GRANT EXECUTE ON FUNCTION mark_chat_read(uuid) TO authenticated;

-- 3. Recompute unread_count from last_read_at (private) instead of the message
--    read receipt. Everything else in the function is unchanged from 00038.
CREATE OR REPLACE FUNCTION get_user_chats_with_metadata(p_chat_ids uuid[] DEFAULT NULL::uuid[])
RETURNS TABLE(
  id uuid,
  created_at timestamptz,
  updated_at timestamptz,
  created_by uuid,
  name text,
  description text,
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
