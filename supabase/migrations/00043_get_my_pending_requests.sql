-- 00043_get_my_pending_requests.sql
--
-- Outgoing (own) join-request overview for the requester (Task #102).
--
-- A user who has only REQUESTED to join a group is not yet a member, so the
-- `chats` SELECT RLS policy ("Members can view their chats", 00005) hides the
-- chat row from them. They can read their own `pending_chat_members` rows
-- (policy "Users can view own pending requests"), but cannot resolve the group
-- NAME — so a "my requests" list could only show the raw chat_id.
--
-- This SECURITY DEFINER function returns the caller's OWN pending requests
-- joined to the group name. It is strictly scoped to `auth.uid()`, so a caller
-- can only ever see groups they themselves requested to join (whose id they
-- already hold, having scanned/entered it). It exposes only the group's display
-- metadata (name, is_group) plus the request timestamps — no member list, no
-- messages, no other chat internals. Read-only; changes no data or schema.

CREATE OR REPLACE FUNCTION get_my_pending_requests()
RETURNS TABLE (
  chat_id uuid,
  chat_name text,
  is_group boolean,
  created_at timestamptz,
  blocked_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    p.chat_id,
    c.name AS chat_name,
    c.is_group,
    p.created_at,
    p.blocked_at
  FROM pending_chat_members p
  JOIN chats c ON c.id = p.chat_id
  WHERE p.user_id = auth.uid()
  ORDER BY p.created_at DESC;
$$;

-- Only authenticated callers; the body scopes strictly to auth.uid()'s own
-- pending rows, so a caller can never see another user's requests.
REVOKE ALL ON FUNCTION get_my_pending_requests() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_my_pending_requests() TO authenticated;
