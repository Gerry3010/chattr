<!--
SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
SPDX-License-Identifier: AGPL-3.0-or-later
-->
# Admin dashboard + moderation — deploy & verify runbook

Internal, privacy-first operator console for Chattr. **Content-blind by design:**
the server never decrypts a message; every metric and moderation action runs on
metadata + evidence a participant voluntarily reveals. Plan: `wise-plotting-lagoon.md`.

## What ships here
- **Migrations** `00058` (metrics), `00059` (last_active/DAU), `00060` (reports + moderation),
  `00061` (operator accounts, admin settings, multi-watchlists, audit log).
- **Edge function** `supabase/functions/admin-stats` — network-gated on `ADMIN_STATS_SECRET`,
  plus a per-operator **HMAC session** once any operator exists.
- **App** `lib/features/reports/` + `lib/features/presence/` + a server report from the chat menu.
- **Dashboard** `landing/admin/index.html` (static SPA: Overview / Reports / Signals / Users /
  Settings) + `landing/admin/presets/*.json` (optional profanity watchlist presets).
- **Hosting** `scripts/netcup/caddy/…` + `scripts/netcup/setup-admin-dashboard.sh` (prod),
  `scripts/staging/setup-staging-admin-nginx.sh` (staging).

## Operators, roles & settings
- **0 operators = legacy single-operator mode** — the network gate (secret + basic_auth [+ mTLS])
  is enough; the UI acts as admin so you can create the first operator. Once an operator exists,
  **login is required** (username + bcrypt password; `admin` or `moderator` role). Sessions are
  stateless HMAC tokens signed with `ADMIN_STATS_SECRET` (12h), held in the tab's sessionStorage.
- **Roles:** `admin` sees Settings (operators, thresholds, watchlists, audit); `moderator` sees
  Overview / Reports / Signals / Users and can ban/unban/resolve/restore — everything is
  **attributed** in the audit log (`admin_audit`).
- **Settings tab (admin):** add/disable operators + change role/password; tune moderation
  thresholds (`content_gate_cap`, `false_flag_threshold`, `false_flag_decay_months` — previously
  hardcoded, now `admin_settings`); manage **multiple watchlists** (create/rename/enable-disable/
  delete, per-list terms, JSON **import/export**, and **preset import** from
  `landing/admin/presets/`). Only **enabled** lists feed `abuse_signals`. Watchlists scan
  plaintext usernames/group names only — never messages.
- **Users tab:** ban/unban by id out-of-band + browse banned users/groups and flagging-revoked
  reporters. **Transparency export** (Settings) downloads anonymous aggregate CSV.

## Bound mode — the secret lives on the server, never in the browser
The panel is **bound to Supabase**: an `admin-proxy` sidecar (`nginx:alpine`) runs *inside* the
Supabase compose stack. It serves the static dashboard **and** reverse-proxies `/functions/*` to
`kong:8000` on the internal Docker network, injecting `Authorization: Bearer $ADMIN_STATS_SECRET`
**server-side**. The browser fetches same-origin with **no** secret. The secret exists only in the
stack `.env` (read by both the `functions` and `admin-proxy` containers).

The sidecar publishes on `127.0.0.1:8899` (prod) / `127.0.0.1:8199` (staging, remapped by
`make-staging-compose.sh`). The static root is bind-mounted from `landing/admin` (prod
`../landing/admin`, staging `../admin` — set via `ADMIN_PANEL_ROOT`). The dashboard JS defaults to
**auto/bound mode** (same-origin, no header); the old connect gate remains only as a **dev
fallback** for pointing a locally-opened file at a remote API with a hand-entered secret.

## Hosting & auth — layered gates (basic_auth + API secret + optional mTLS + operator login)
The host-level reverse proxy terminates **TLS + basic_auth** (and **optionally mTLS**) and forwards
to the sidecar, which injects `ADMIN_STATS_SECRET`. On top, an **operator login** identifies who.

**mTLS is a config toggle — `ADMIN_MTLS` (default `off` in the shipped setup scripts):**
- `ADMIN_MTLS=require` → the proxy requires a client cert signed by our private CA before any HTTP
  (only enrolled devices complete the handshake). **This is what Gerry's boxes run.**
- `ADMIN_MTLS=off` → basic_auth only — no CA/cert hurdle, so anyone can self-host easily.
- Staging (nginx): `ADMIN_MTLS=require scripts/staging/setup-staging-admin-nginx.sh`.
- Prod (Caddy): `ADMIN_MTLS=require scripts/netcup/setup-admin-dashboard.sh` (the helper strips the
  `tls { client_auth … }` block from the site file when `off`).
Client certs are issued with `scripts/admin-mtls/make-ca-and-cert.sh`; upload the CA to the box.

| | Host | Proxy | URL |
|---|---|---|---|
| **staging** | IONOS `<staging-host>` | nginx | `staging-admin.chattr.geraldhofbauer.net` |
| **prod** | netcup `<prod-host>` | Caddy | `admin.chattr.geraldhofbauer.net` |

**Prerequisites (once):**
1. **Gate secret** → Bitbucket repo var `ADMIN_STATS_SECRET` (secured; **not** the service-role key). *(set)*
2. **DNS** (via `cf`, both DNS-only): `admin.chattr…→<prod-host>`, `staging-admin.chattr…→<staging-host>`. *(set)*
3. **Client cert (mTLS):** run `scripts/admin-mtls/make-ca-and-cert.sh` locally → import `<device>.p12`
   into your browser/keychain; `scp` the generated `ca.crt` to `~/chattr-admin-ca.crt` on **both** boxes.
4. **Enable the vhost:**
   - staging (IONOS): `scripts/staging/setup-staging-admin-nginx.sh` — CA + basic_auth + certbot, `ssl_verify_client on`.
   - prod (netcup): `scripts/netcup/setup-admin-dashboard.sh` (or the standalone Caddy script) — adds
     `tls { client_auth … }` + basic_auth, auto-HTTPS.
   The static dashboard file is deployed by the pipeline (`landing/admin` → staging `.../staging/admin`,
   prod `.../app/landing/admin`).

## Deploy — **staging first** (standing rule)
Prod-affecting changes go through staging before `main`.

1. Push this branch to `staging` → `build-staging` + `deploy-staging` run. The pipeline now
   injects `ADMIN_STATS_SECRET` into the staging `.env`; `docker-compose.yml` passes it to the
   functions container. Migrations `00058-00060` apply via `migrate`.
2. **Smoke-test the API against staging** (Kong on the staging host):
   ```bash
   BASE=https://<staging-api-host>            # staging Kong external URL
   SEC=<ADMIN_STATS_SECRET>
   curl -s -o /dev/null -w '%{http_code}\n' "$BASE/functions/v1/admin-stats?action=stats"      # → 401
   curl -s -H "Authorization: Bearer $SEC" "$BASE/functions/v1/admin-stats?action=stats&bucket=day" | jq .
   curl -s -H "Authorization: Bearer $SEC" "$BASE/functions/v1/admin-stats?action=reports" | jq '.reports|length'
   curl -s -H "Authorization: Bearer $SEC" "$BASE/functions/v1/admin-stats?action=signals" | jq '.signals|length'
   ```
3. **Enforcement check** (SQL on staging): ban a throwaway user via
   `select mod_ban_user('<uuid>')`, confirm a `messages` insert for them raises
   `check_violation`, then `select mod_unban_user('<uuid>')`.
   > Note: those curl reads work as-is only in **legacy mode (0 operators)**. Once an operator
   > exists, reads/actions need an operator session: `POST …?action=login {username,password}` →
   > send the returned token as `X-Admin-Session:` (still behind the `Authorization` network gate).
4. **Dashboard**: open `https://<staging-admin-host>/admin/` (bound mode — no secret in the
   browser) → log in as an operator → all five tabs (Overview/Reports/Signals/Users/Settings)
   route; KPIs/charts render; badge hides at 0; Settings CRUD (operator/threshold/watchlist)
   round-trips and shows in the audit log; a `ban`/`resolve` button works.
5. **App**: two-user flow — report a chat → a `reports` row appears (metadata only, no content);
   `touch_last_active` bumps `profiles.last_active_date` (day only) on resume.

## Promote to prod
PR `feat/admin-dashboard` → `main`. Prod deploy injects `ADMIN_STATS_SECRET`, applies migrations,
syncs the function, re-serves `landing/admin`. Re-run the curl smoke tests against
`https://api.chattr.geraldhofbauer.net`.

## Privacy guardrails (enforced, do not weaken)
- No server-side decryption — ever. `metrics_daily` stores only day + count (no user linkage).
- Reveal content only via `reveal_reported_message` (accused self-reveal any time; recipient once
  `distinct reporters ≥ min(3, N)`). `mod_resolve_report` purges revealed content on close.
- Name watchlist (`moderation_terms`) scans ONLY plaintext identifiers (username / group
  name+description) — never a message. This is **not** client-side scanning; the CSS pledge holds.
- `moderation_terms` is **DB data, not committed** — populate on the box, keep it out of the repo.
- Dashboard behind Caddy `basic_auth`; the fn secret is a second layer and is **never** the
  service-role key. All aggregate RPCs are `REVOKE`d from public and granted to `service_role` only.

## Open follow-ups
- **Per-message flag UI + accused self-reveal banner** (task #9): chatview long-press → reason
  picker → `reportUser(messageId)`; a banner from `myReportedMessagesProvider` that signs the
  plaintext with the identity key and calls `revealMessage`. Backend RPCs already shipped in 00060.
- **OSS go-live gate**: this feature ships public — public GitHub mirror, rotate the FCM test key,
  final secret sweep, GH security scanning (secret-scanning/Dependabot/CodeQL + Semgrep suite +
  Claude PR review). See the plan's "Go-Live-Gate" section.
- Optional: self-host IBM Plex woff2 for the console (currently a system mono/sans stack);
  public transparency report reusing the same aggregates.
