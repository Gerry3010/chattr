-- SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
-- SPDX-License-Identifier: AGPL-3.0-or-later

-- Per-recipient total unread, for the push notification's APNs `aps.badge`.
--
-- The send-push-notification Edge Function (service_role) sets
-- `aps.badge` = the recipient's TOTAL unread across all chats (including the
-- just-delivered message), so iOS shows the correct app-icon badge while the
-- app is backgrounded — an absolute value APNs applies without the app running.
--
-- This uses the SAME `last_read_at`-based count as get_user_chats_with_metadata
-- (migration 00053), summed per user, so the server badge matches the client's
-- totalUnreadProvider exactly (no jump between a background push and the
-- foreground read count). Batched over all recipients of one push in one call.

CREATE OR REPLACE FUNCTION unread_totals(p_user_ids uuid[])
RETURNS TABLE(user_id uuid, unread bigint)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  -- One row per user that has ≥1 unread; users with 0 unread are simply absent
  -- (the Edge Function defaults a missing user to 0). Each message is counted
  -- once: (chat_id, recipient_id) picks exactly the caller's own row, and a user
  -- has a single membership per chat.
  SELECT cm.user_id, COUNT(m.*)::bigint AS unread
  FROM chat_members cm
  JOIN messages m
    ON m.chat_id = cm.chat_id
   AND m.recipient_id = cm.user_id
   AND m.created_at > COALESCE(cm.last_read_at, '-infinity'::timestamptz)
  WHERE cm.user_id = ANY(p_user_ids)
  GROUP BY cm.user_id;
$$;

-- Only the scheduled/service-role push sender needs this; never client-callable.
REVOKE ALL ON FUNCTION unread_totals(uuid[]) FROM public;
REVOKE ALL ON FUNCTION unread_totals(uuid[]) FROM anon;
REVOKE ALL ON FUNCTION unread_totals(uuid[]) FROM authenticated;
GRANT EXECUTE ON FUNCTION unread_totals(uuid[]) TO service_role;

COMMENT ON FUNCTION unread_totals(uuid[]) IS
  'Total unread per recipient (last_read_at-based, matches get_user_chats_with_metadata) for the push aps.badge. service_role only.';
