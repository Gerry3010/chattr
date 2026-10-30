-- ============================================================================
-- 00040: Recovery-phrase credentials (durable, file-less identity recovery)
-- ----------------------------------------------------------------------------
-- Anonymous Chattr accounts have no re-login. This backs the Phase-2 recovery
-- flow: a 24-word phrase deterministically derives an Ed25519 keypair whose
-- PUBLIC key is enrolled here (server-side, via the enroll-recovery edge
-- function). On a fresh device the user proves possession of the phrase
-- (private key) through a challenge-response to the recover-identity edge
-- function, which then mints a session for the ORIGINAL user_id via the admin
-- API (admin.generateLink → verifyOtp). No email is ever shown to the user and
-- public email auth stays disabled — a random synthetic email is attached
-- server-side purely so generateLink works.
--
-- Both tables are touched ONLY by the two edge functions (service_role, which
-- bypasses RLS). No app client ever reads/writes them directly, so RLS is
-- enabled with NO permissive policies = deny-all for anon/authenticated.
-- ============================================================================

CREATE TABLE IF NOT EXISTS recovery_credentials (
  user_id             UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  recovery_public_key TEXT NOT NULL UNIQUE,       -- base64 Ed25519 public key (32 B)
  synthetic_email     TEXT NOT NULL UNIQUE,       -- server-set, never shown to the user
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE recovery_credentials IS 'Enrolled recovery-phrase public keys. The phrase itself is never stored; possession is proven via Ed25519 challenge-response in the recover-identity edge function. Written only by edge functions (service_role).';

-- One in-flight challenge per public key (a new challenge overwrites the old).
CREATE TABLE IF NOT EXISTS recovery_challenges (
  recovery_public_key TEXT PRIMARY KEY,
  challenge           TEXT NOT NULL,              -- random, base64
  expires_at          TIMESTAMPTZ NOT NULL
);

COMMENT ON TABLE recovery_challenges IS 'Short-lived, single-use challenges for recovery-phrase proof-of-possession. Written/consumed only by the recover-identity edge function (service_role).';

-- Lock both tables down: enable RLS, define NO policies → only service_role
-- (which bypasses RLS) can touch them. No app-client access whatsoever.
ALTER TABLE recovery_credentials ENABLE ROW LEVEL SECURITY;
ALTER TABLE recovery_challenges  ENABLE ROW LEVEL SECURITY;

NOTIFY pgrst, 'reload schema';
