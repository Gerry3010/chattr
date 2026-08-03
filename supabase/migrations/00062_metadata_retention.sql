-- =====================================================
-- Metadata retention hardening (metadata audit 2026-08-02, findings D1/D2/D6a)
-- =====================================================
-- The message CONTENT is already cleared on delivery. What survived was the
-- metadata ROW around it — and in one case it survived forever.
--
-- D1 — the read-receipt privacy trap. cleanup_old_messages() had exactly two
--   rules: "read and older than 7 days", or "never received and older than 30
--   days". A user who turns read receipts OFF makes the client skip
--   mark_message_read() on purpose, so read_at stays NULL while received_at is
--   set. Such a row matches NEITHER rule and is therefore kept forever:
--   (chat_id, sender_id, recipient_id, created_at, received_at, reply_to_*) —
--   a permanent, growing social graph with timestamps.
--   The irony: enabling the privacy setting produced MORE lasting metadata
--   than leaving it off. This adds the missing third rule.
--
-- D2 — mark_message_received() cleared encrypted_content but left
--   reply_to_preview (the per-recipient ciphertext of the quote) and
--   reply_to_sender_name (a PLAINTEXT username) in place. Combined with D1, a
--   contentless row still stated "this was a reply to Anna, at 02:14".
--   The client persists the decrypted quote locally on receipt, so the server
--   copy has no reader after delivery.
--
-- D6a — message_reactions has no FK to messages (composite PK there), so
--   reactions outlived the message they describe, with no retention at all.
--   Mirrors the media_downloads orphan sweep that already exists.
--
-- No client change is required and no client breaks: every column stays, only
-- their lifetime changes.

-- ---------------------------------------------------------------------------
-- D2: clear the reply metadata at delivery, like the content
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION mark_message_received(
  p_message_id UUID,
  p_chat_id UUID
)
RETURNS VOID
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
BEGIN
  UPDATE messages
  SET
    received_at = NOW(),
    encrypted_content = '',
    -- Delivered: the recipient has persisted the decrypted quote locally, so
    -- nothing server-side still needs these. Leaving them kept a plaintext
    -- username and a quote ciphertext next to a row we otherwise emptied.
    reply_to_preview = NULL,
    reply_to_sender_name = NULL
  WHERE id = p_message_id
    AND chat_id = p_chat_id
    AND recipient_id = auth.uid()
    AND received_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Message not found or already received';
  END IF;
END;
$$;
COMMENT ON FUNCTION mark_message_received IS
  'Marks a message as received for the current user and clears the encrypted content plus the reply-quote metadata (preview + sender name). Can only be called by the recipient.';

-- ---------------------------------------------------------------------------
-- D1 + D6a: retention
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cleanup_old_messages()
RETURNS INTEGER
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
DECLARE
  deleted_read_count INTEGER;
  deleted_delivered_count INTEGER;
  deleted_unread_count INTEGER;
  total_deleted INTEGER;
BEGIN
  -- Read and older than 7 days.
  DELETE FROM messages
  WHERE read_at IS NOT NULL
    AND read_at < NOW() - INTERVAL '7 days';

  GET DIAGNOSTICS deleted_read_count = ROW_COUNT;

  -- D1: delivered but never marked read, older than 7 days. This is the normal
  -- state for a recipient with read receipts disabled — the content is long
  -- gone (mark_message_received cleared it), only the metadata row remained.
  -- Senders lose the delivery status for such messages after 7 days, exactly
  -- as they already lose the read status above; get_sent_message_status
  -- (00042) works off a client-side watermark and tolerates missing rows.
  DELETE FROM messages
  WHERE read_at IS NULL
    AND received_at IS NOT NULL
    AND received_at < NOW() - INTERVAL '7 days';

  GET DIAGNOSTICS deleted_delivered_count = ROW_COUNT;

  -- Never received and older than 30 days (recipient never came online).
  DELETE FROM messages
  WHERE received_at IS NULL
    AND created_at < NOW() - INTERVAL '30 days';

  GET DIAGNOSTICS deleted_unread_count = ROW_COUNT;

  -- Sweep download confirmations whose message is gone (orphans).
  DELETE FROM media_downloads d
  WHERE NOT EXISTS (
    SELECT 1 FROM messages m WHERE m.id = d.message_id
  );

  -- D6a: same for reactions. message_reactions deliberately has no FK to
  -- messages (composite PK over there), so nothing cascaded and the emoji —
  -- which is stored in PLAINTEXT — outlived the message it referred to.
  DELETE FROM message_reactions r
  WHERE NOT EXISTS (
    SELECT 1 FROM messages m WHERE m.id = r.message_id
  );

  total_deleted :=
    deleted_read_count + deleted_delivered_count + deleted_unread_count;

  RAISE NOTICE 'Message cleanup: % read (>7d), % delivered-unread (>7d), % undelivered (>30d). Total: %',
    deleted_read_count, deleted_delivered_count, deleted_unread_count,
    total_deleted;

  RETURN total_deleted;
END;
$$;
COMMENT ON FUNCTION cleanup_old_messages IS
  'Deletes read messages older than 7 days, delivered-but-unread messages older than 7 days (the read-receipts-off case), and undelivered messages older than 30 days; sweeps orphaned media_downloads and message_reactions rows.';
