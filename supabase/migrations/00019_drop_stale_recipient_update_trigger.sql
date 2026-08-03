-- Production schema-drift fix.
--
-- The legacy migration sequence (migrations_backup/00015) created a trigger
-- `enforce_message_update_columns` (function `check_message_update_columns`)
-- plus a "Recipients can update message status" UPDATE policy on `messages`.
-- They forbid a recipient from changing `encrypted_content`.
--
-- The current schema instead clears `encrypted_content` INSIDE the SECURITY
-- DEFINER functions mark_message_received() / mark_message_read() (forward
-- secrecy on receipt/read) and gives recipients NO direct UPDATE policy at all
-- (only "Senders can update their messages"). So the legacy trigger is both
-- unnecessary and harmful: on databases first built from the old sequence
-- (production) it still fires and raises
--   "Recipients can only update received_at and read_at columns"
-- whenever a recipient marks a message received, which makes inbound messages
-- never reach the recipient's UI (GlobalMessageHandler throws).
--
-- Drop the stale objects. IF EXISTS makes this a no-op on clean current-schema
-- databases (local/CI) and a clean reconciliation on production.

DROP TRIGGER IF EXISTS enforce_message_update_columns ON messages;
DROP FUNCTION IF EXISTS check_message_update_columns();
DROP POLICY IF EXISTS "Recipients can update message status" ON messages;
