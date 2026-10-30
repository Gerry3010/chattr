<!--
SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Security Policy

Chattr is an end-to-end encrypted messenger. Its security is the whole point, so
we publish the source (AGPL-3.0) precisely so the claims below can be verified
rather than trusted.

## Reporting a vulnerability

**Please do not open a public issue for security vulnerabilities.**

Email **info@geraldhofbauer.net** with:

- a description of the issue and its impact,
- steps to reproduce (a proof of concept if you have one),
- the affected version / commit.

You'll get an acknowledgement as soon as possible. We'll work with you on a fix
and coordinate disclosure; we're happy to credit you unless you prefer to stay
anonymous. Please give us reasonable time to ship a fix before disclosing
publicly.

## Scope

In scope: the Flutter app (`lib/`), the crypto core (`native/chattr_crypto`,
`web_crypto`), the Supabase backend (`supabase/migrations`, `supabase/functions`),
the MCP server (`mcp_server`), and the admin/moderation surface (`landing/admin`,
`admin-stats`).

Out of scope: third-party infrastructure (Supabase, Firebase, hosting), and
issues that require a compromised device or a malicious OS.

## Security invariants (what a review should hold us to)

These are the promises that make Chattr trustworthy. A change that breaks one is
a security bug, even if nothing "fails":

1. **The server is content-blind.** Messages are hybrid-encrypted per recipient
   (X25519 + ML-KEM-768 wrapping AES-256-GCM). The server stores ciphertext only
   and clears it once delivered. No server-side path decrypts, logs, or
   exfiltrates plaintext or private keys.
2. **No backdoor.** Moderation acts on metadata (`message_id`, `chat_id`,
   timestamps, counts) and server-plaintext identifiers (usernames, chat names)
   only. Reported message content is revealed only by cryptographically
   attested, **voluntary** disclosure from the accused sender, or gated behind
   `min(3, N)` distinct reporters — never by a server key.
3. **Never client-side scanning.** Chattr will never scan, hash, or classify
   message content on the device (CSS / "Chat Control"). If that were ever
   legally mandated, the app goes offline rather than scan.
4. **Envelope integrity.** Every message carries an Ed25519 identity signature
   and an AAD binding to `chat_id‖sender_id‖message_id`; the hybrid
   (post-quantum) scheme is enforced with no silent downgrade to classical-only.
5. **Least privilege at the DB.** Row-Level Security protects every table;
   recipients change message status only through dedicated `SECURITY DEFINER`
   RPCs; aggregate/admin RPCs `REVOKE EXECUTE FROM public`.
6. **Secrets are environment-only.** No keys, tokens, passwords, service-role
   keys, or admin gate secrets are ever committed to this repository.

## Supported versions

Security fixes target the latest released version. Chattr is under active
development; please test against `main` before reporting.
