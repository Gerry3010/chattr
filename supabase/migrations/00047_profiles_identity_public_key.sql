-- SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
-- SPDX-License-Identifier: AGPL-3.0-or-later

-- ============================================================================
-- Security audit 2026-07-16 — P0-a: long-term per-user identity key.
--
-- Introduces the trust anchor that closes C1 (server can transparently MITM):
-- a stable Ed25519 identity public key per user. Clients generate it once,
-- publish the base64 public key here, embed it in their QR for TOFU pinning,
-- and use it to sign each per-chat KEM key (so a key-swapping server is
-- detectable) and — from PR2 — to sign messages.
--
-- Readability is already correctly scoped by migration 00046: the profiles
-- SELECT policy (can_view_profile) lets a caller read this column only for
-- self / co-members / pending requesters in their chats / blocked users. Writes
-- are self-only via the existing "Users can update their own profile" policy
-- (WITH CHECK auth.uid() = id). No new policy needed.
-- ============================================================================

ALTER TABLE profiles
  ADD COLUMN IF NOT EXISTS identity_public_key TEXT;

COMMENT ON COLUMN profiles.identity_public_key IS
  'Base64 Ed25519 long-term identity public key (32 B). Trust anchor for '
  'key-verification / safety numbers and per-chat KEM-key + message signatures '
  '(audit 2026-07-16, C1/H1). Rotated on account recovery (Signal model).';
