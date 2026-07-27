-- 00027: Sender-side edit + unsend via SECURITY DEFINER functions.
--
-- Direct UPDATE/DELETE from the client never touched any rows: PostgreSQL
-- also applies the SELECT policy to rows referenced by an UPDATE/DELETE's
-- WHERE clause, and the messages SELECT policy is recipient-only — a sender
-- has no recipient row of their own message, so "Senders can update their
-- messages" / "Senders can delete unread messages" were unreachable and the
-- statements silently matched zero rows (PostgREST reports success).
-- Editing and unsending therefore only ever changed the sender's local copy.
--
-- Follow the existing pattern (mark_message_received/mark_message_read):
-- dedicated functions that enforce sender ownership explicitly.

-- Replace every recipient's ciphertext with a freshly re-encrypted version
-- and stamp edited_at. p_contents maps recipient_id -> new ciphertext.
-- The per-row UPDATE fires notify_message_update (content_changed), so live
-- recipients re-fetch and re-decrypt. Returns the number of rows updated.
CREATE OR REPLACE FUNCTION edit_message(
    p_message_id UUID,
    p_chat_id UUID,
    p_contents JSONB
) RETURNS INTEGER AS $$
DECLARE
    v_entry RECORD;
    v_rows INTEGER;
    v_count INTEGER := 0;
BEGIN
    FOR v_entry IN SELECT key, value FROM jsonb_each_text(p_contents) LOOP
        UPDATE messages
        SET encrypted_content = v_entry.value,
            edited_at = NOW()
        WHERE id = p_message_id
          AND chat_id = p_chat_id
          AND recipient_id = v_entry.key::uuid
          AND sender_id = auth.uid();
        GET DIAGNOSTICS v_rows = ROW_COUNT;
        v_count := v_count + v_rows;
    END LOOP;
    RETURN v_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- Unsend: delete all recipient copies of the sender's message that have not
-- been read yet (same rule as the old, unreachable DELETE policy). Fires
-- message_delete_trigger per row so recipients get the messageDelete event.
-- Returns the number of rows deleted.
CREATE OR REPLACE FUNCTION delete_message_for_everyone(
    p_message_id UUID,
    p_chat_id UUID
) RETURNS INTEGER AS $$
DECLARE
    v_count INTEGER;
BEGIN
    DELETE FROM messages
    WHERE id = p_message_id
      AND chat_id = p_chat_id
      AND sender_id = auth.uid()
      AND read_at IS NULL;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION edit_message(UUID, UUID, JSONB) IS
    'Sender re-encrypts an edited message for all recipients; sets edited_at. Sender-owned rows only.';
COMMENT ON FUNCTION delete_message_for_everyone(UUID, UUID) IS
    'Sender unsends an unread message for all recipients. Sender-owned rows only.';
