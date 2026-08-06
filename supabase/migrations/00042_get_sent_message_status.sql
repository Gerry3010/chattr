-- 00042_get_sent_message_status.sql
--
-- Read-receipt BACKFILL for the sender (fixes: receipts missed while the
-- sender's client was closed).
--
-- Receipts reach the sender only via the notify_message_update broadcast
-- (00003, SECURITY DEFINER, targeted at `user:<sender_id>`). If the sender's
-- client is offline/closed when a recipient marks a message received or read,
-- that broadcast is lost and there is no way to recover it: migration 00010
-- deliberately dropped the sender-inclusive SELECT policy (it let a sender read
-- every per-recipient row), leaving only `recipient_id = auth.uid()`. So a
-- sender cannot SELECT the received_at/read_at of their OWN sent rows at all.
--
-- This SECURITY DEFINER function is a STATUS-ONLY backfill: it returns the
-- delivery/read timestamps of the caller's sent messages (all recipient rows,
-- so group ticks reconcile correctly), letting the client reconcile ticks on
-- start/resume. It exposes no ciphertext (already cleared by mark_message_*)
-- and no other column. Read-only; changes no data or schema.
--
-- `p_since` is a client-held watermark (max received_at/read_at already seen);
-- NULL on first run returns all still-tracked rows.

CREATE OR REPLACE FUNCTION get_sent_message_status(p_since timestamptz DEFAULT NULL)
RETURNS TABLE (
  id uuid,
  chat_id uuid,
  recipient_id uuid,
  received_at timestamptz,
  read_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT m.id, m.chat_id, m.recipient_id, m.received_at, m.read_at
  FROM messages m
  WHERE m.sender_id = auth.uid()
    AND (m.received_at IS NOT NULL OR m.read_at IS NOT NULL)
    AND (
      p_since IS NULL
      OR m.received_at >= p_since
      OR m.read_at >= p_since
    );
$$;

-- Only authenticated callers; the body scopes strictly to auth.uid()'s own sent
-- rows, so a caller can never see another user's data.
REVOKE ALL ON FUNCTION get_sent_message_status(timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_sent_message_status(timestamptz) TO authenticated;
