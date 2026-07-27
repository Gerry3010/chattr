-- 00025: Explicit edit marker for messages.
--
-- The "Edited" label used to be inferred from updated_at > created_at, which
-- can never work: messages_updated_at_trigger (00004) bumps updated_at on
-- EVERY row update (mark_message_received / mark_message_read), and even at
-- insert the server-side updated_at (NOW()) differs from the client-supplied
-- created_at. Any resync that re-fetched a delivered row therefore showed a
-- false "Edited" label.
--
-- edited_at is set only by the sender's edit UPDATE (re-encrypting the
-- content); NULL = never edited. No backfill: the old inference produced
-- false positives, so historical rows intentionally stay NULL.

ALTER TABLE messages ADD COLUMN IF NOT EXISTS edited_at TIMESTAMPTZ;

COMMENT ON COLUMN messages.edited_at IS
    'Set by the sender when re-encrypting an edited message; NULL = never edited.';
