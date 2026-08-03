-- ============================================================================
-- 00013: Message edit propagation
-- ----------------------------------------------------------------------------
-- Stage 7.3 — let a sender edit a message they sent. The sender re-encrypts the
-- new plaintext for every recipient and UPDATEs each per-recipient row's
-- `encrypted_content`. We extend notify_message_update so that, in addition to
-- the existing sender-facing status notifications (received/read), a recipient
-- is notified when the ciphertext of *their* row actually changes to a new,
-- non-empty value — i.e. a real edit, not the clear-on-read that
-- mark_message_read()/mark_message_received() perform.
--
-- The recipient client reacts by re-fetching its row, decrypting the new
-- ciphertext and replacing the message content locally + in the UI.
-- ============================================================================

CREATE OR REPLACE FUNCTION notify_message_update()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = ''
LANGUAGE plpgsql
AS $$
DECLARE
  updates_json JSONB;
BEGIN
  -- 1) Status changes (received/read) → notify the sender (read receipts).
  updates_json := jsonb_build_object();

  IF OLD.received_at IS DISTINCT FROM NEW.received_at THEN
    updates_json := updates_json || jsonb_build_object('received_at', NEW.received_at);
  END IF;

  IF OLD.read_at IS DISTINCT FROM NEW.read_at THEN
    updates_json := updates_json || jsonb_build_object('read_at', NEW.read_at);
  END IF;

  IF updates_json != '{}'::jsonb AND NEW.sender_id IS NOT NULL THEN
    PERFORM realtime.send(
      jsonb_build_object(
        'type', 'messageUpdate',
        'chat_id', NEW.chat_id,
        'message_id', NEW.id,
        'recipient_id', NEW.recipient_id,
        'updates', updates_json,
        'timestamp', NOW()
      ),
      'event',
      'user:' || NEW.sender_id,
      FALSE
    );
  END IF;

  -- 2) Content edit → notify the recipient so they re-fetch + re-decrypt.
  --    Only when the ciphertext changed to a non-empty value: the clear that
  --    happens on read/receive sets it to '' / NULL and must NOT be treated as
  --    an edit (and must not be sent back to the recipient as new content).
  IF OLD.encrypted_content IS DISTINCT FROM NEW.encrypted_content
     AND COALESCE(NEW.encrypted_content, '') <> ''
     AND NEW.recipient_id IS NOT NULL
     AND NEW.recipient_id <> NEW.sender_id THEN
    PERFORM realtime.send(
      jsonb_build_object(
        'type', 'messageUpdate',
        'chat_id', NEW.chat_id,
        'message_id', NEW.id,
        'recipient_id', NEW.recipient_id,
        'updates', jsonb_build_object('content_changed', true),
        'timestamp', NOW()
      ),
      'event',
      'user:' || NEW.recipient_id,
      FALSE
    );
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION notify_message_update IS
  'Notifies the sender on status change (received/read) and the recipient on a real content edit (new non-empty ciphertext).';
