-- SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
-- SPDX-License-Identifier: AGPL-3.0-or-later
-- ============================================================================
-- 00090: A sent message may be edited for a limited time only
-- ----------------------------------------------------------------------------
-- edit_message (00027) had no time limit at all. In practice an edit worked
-- until the retention job (00062) removed the rows, 7 days after reading —
-- and after that the server updated nothing while the app still offered the
-- button (Gerry, 2026-10-05: "das müssen wir fixen — und viel kürzer").
--
-- The rule:
--   * unread by everyone: up to 24 hours after sending;
--   * read by anyone:     up to 10 minutes after the FIRST read (Gerry);
--   * never later than 24 hours after sending.
-- A correction long after someone has read — and maybe answered — would
-- change what they answered to.
--
-- The client offers the edit by the same rule (edit_window.dart). The server
-- is the one that decides: it knows read_at even where the sender's device
-- does not (read receipts off), and a client can be old or altered.
-- Refusal carries a stable message ('edit_window_closed') the client maps to
-- a sentence.
-- ============================================================================

CREATE OR REPLACE FUNCTION edit_message(
    p_message_id UUID,
    p_chat_id UUID,
    p_contents JSONB
) RETURNS INTEGER AS $$
DECLARE
    v_entry RECORD;
    v_rows INTEGER;
    v_count INTEGER := 0;
    v_sent TIMESTAMPTZ;
    v_first_read TIMESTAMPTZ;
    v_deadline TIMESTAMPTZ;
BEGIN
    SELECT min(created_at), min(read_at)
      INTO v_sent, v_first_read
      FROM messages
     WHERE id = p_message_id
       AND chat_id = p_chat_id
       AND sender_id = auth.uid();

    IF v_sent IS NULL THEN
        -- Not ours, or the rows are gone (retention): nothing to edit.
        RETURN 0;
    END IF;
    -- Computed apart: inside an IF condition PL/pgSQL would take a CASE's
    -- own THEN for the end of the condition.
    v_deadline := v_sent + interval '24 hours';
    IF v_first_read IS NOT NULL THEN
        v_deadline := least(v_deadline, v_first_read + interval '10 minutes');
    END IF;
    IF now() > v_deadline THEN
        RAISE EXCEPTION 'edit_window_closed' USING ERRCODE = 'P0001';
    END IF;

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

COMMENT ON FUNCTION edit_message(UUID, UUID, JSONB) IS
    'Sender re-encrypts an edited message for all recipients; sets edited_at. '
    'Only within 24 h of sending, and no later than 10 min after the first '
    'read (00090).';
