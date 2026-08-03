-- 00049_chat_member_prekeys.sql
--
-- Forward Secrecy (audit P3/L1) — one-time KEM prekey pool.
--
-- Chattr's per-recipient KEM wrap is already ephemeral on the SENDER side (a
-- fresh X25519 + ML-KEM encapsulation per message), but the RECIPIENT unwraps
-- with a STATIC long-lived per-chat key (`chat_pqc_key_<chatId>`). An adversary
-- who logs ciphertext in transit and later compromises a device can therefore
-- unwrap every message ever sent — no forward secrecy.
--
-- Fix (PQXDH-style one-time prekeys): each member publishes a POOL of one-time
-- ephemeral hybrid KEM public keys (same `{"x":..,"m":..,"s":..}` blob, identity
-- signed). A sender atomically CLAIMS one unused prekey per recipient and wraps
-- the message key to it (envelope v5). The recipient decrypts once with the
-- matching private half, then DELETES that private half from its device — after
-- which the logged ciphertext is permanently un-unwrappable. Forward secrecy per
-- message.
--
-- This table holds only the PUBLIC prekey halves + a consumed flag. Private
-- halves never leave the device (local SQLite). The server stays zero-knowledge:
-- public keys and a boolean of availability, nothing that decrypts anything.
--
-- Rollout: "recipient advertises v5" == it has ≥1 unconsumed prekey here. If the
-- pool is empty (older client, or exhausted), the sender falls back to v4 — the
-- same fail-safe, order-independent gate as the v3→v4 rollout.

-- Idempotency (pre-merge, task #134): this migration was applied MANUALLY to
-- prod (00049+00050, Gerry's decision A) ahead of the branch merge, but not
-- recorded in the pipeline's grep-based `.migration_history`. So the deploy
-- pipeline WILL re-run this file. Every statement below is therefore guarded
-- (IF NOT EXISTS / DROP POLICY IF EXISTS / CREATE OR REPLACE) so a second apply
-- is a clean no-op instead of "relation/policy already exists" → broken deploy.

-- ── Table ───────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS chat_member_prekeys (
  chat_id     UUID NOT NULL,
  user_id     UUID NOT NULL,
  prekey_id   TEXT NOT NULL,
  public_blob TEXT NOT NULL,           -- {"x":..,"m":..,"s":..} identity-signed
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  consumed_at TIMESTAMPTZ,             -- NULL = available to claim
  PRIMARY KEY (chat_id, user_id, prekey_id),
  -- Auto-clean a member's prekeys when they leave / are removed from the chat.
  FOREIGN KEY (chat_id, user_id)
    REFERENCES chat_members (chat_id, user_id) ON DELETE CASCADE
);

COMMENT ON TABLE chat_member_prekeys IS
  'One-time KEM prekey pool for forward secrecy (audit P3). Public halves only; '
  'a sender claims one unconsumed prekey per recipient (claim_prekey), the '
  'recipient consumes + deletes the matching private half locally (envelope v5).';

-- Fast "next available prekey" lookup + availability check (the v5 gate).
CREATE INDEX IF NOT EXISTS idx_prekeys_available
  ON chat_member_prekeys (chat_id, user_id, created_at)
  WHERE consumed_at IS NULL;

-- ── RLS ─────────────────────────────────────────────────────────────────────
ALTER TABLE chat_member_prekeys ENABLE ROW LEVEL SECURITY;

-- Co-members of a chat may READ prekey rows in it: a sender needs peers' public
-- prekeys, and a member needs to count its own remaining prekeys to decide when
-- to replenish. Public keys only — no secret is exposed. is_chat_member()
-- bypasses RLS to avoid recursion (00002).
DROP POLICY IF EXISTS prekeys_select_co_member ON chat_member_prekeys;
CREATE POLICY prekeys_select_co_member ON chat_member_prekeys
  FOR SELECT TO authenticated
  USING (is_chat_member(chat_id, auth.uid()));

-- A member may publish ONLY its own prekeys, and only in chats it belongs to.
DROP POLICY IF EXISTS prekeys_insert_self ON chat_member_prekeys;
CREATE POLICY prekeys_insert_self ON chat_member_prekeys
  FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid() AND is_chat_member(chat_id, auth.uid()));

-- A member may DELETE ONLY its own prekeys (cleanup of consumed/stale ones on
-- replenish). Consumption itself is done by claim_prekey (SECURITY DEFINER),
-- not by a direct client UPDATE — so there is no UPDATE policy.
DROP POLICY IF EXISTS prekeys_delete_self ON chat_member_prekeys;
CREATE POLICY prekeys_delete_self ON chat_member_prekeys
  FOR DELETE TO authenticated
  USING (user_id = auth.uid());

-- ── Atomic claim RPC ────────────────────────────────────────────────────────
-- Picks and consumes ONE unconsumed prekey belonging to recipient p_user_id, on
-- behalf of the calling co-member (auth.uid()). FOR UPDATE SKIP LOCKED makes
-- concurrent senders each grab a DIFFERENT prekey (never the same one twice —
-- reuse would break FS for that pair). Returns nothing when the pool is
-- exhausted, so the caller falls back to v4.
CREATE OR REPLACE FUNCTION claim_prekey(p_chat_id UUID, p_user_id UUID)
RETURNS TABLE (prekey_id TEXT, public_blob TEXT)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_prekey_id  TEXT;
  v_blob       TEXT;
BEGIN
  -- Only a co-member of the chat may claim its members' prekeys.
  IF NOT is_chat_member(p_chat_id, auth.uid()) THEN
    RETURN;
  END IF;

  SELECT k.prekey_id, k.public_blob
    INTO v_prekey_id, v_blob
  FROM chat_member_prekeys k
  WHERE k.chat_id = p_chat_id
    AND k.user_id = p_user_id
    AND k.consumed_at IS NULL
  ORDER BY k.created_at
  FOR UPDATE SKIP LOCKED
  LIMIT 1;

  IF v_prekey_id IS NULL THEN
    RETURN;  -- pool exhausted → sender uses v4
  END IF;

  UPDATE chat_member_prekeys
     SET consumed_at = NOW()
   WHERE chat_id = p_chat_id
     AND user_id = p_user_id
     AND chat_member_prekeys.prekey_id = v_prekey_id;

  prekey_id   := v_prekey_id;
  public_blob := v_blob;
  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION claim_prekey(UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION claim_prekey(UUID, UUID) TO authenticated;

COMMENT ON FUNCTION claim_prekey IS
  'Atomically claim+consume one unconsumed prekey of p_user_id for the calling '
  'co-member (forward secrecy, audit P3). SKIP LOCKED prevents double-claim.';

-- Realtime is NOT needed for prekeys (senders pull on demand via claim_prekey);
-- deliberately not added to the supabase_realtime publication.
