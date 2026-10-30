<!--
SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# chattr.at cutover plan

> **Status 2026-10-11: Phase 1 is done.** `chattr.at` serves the landing (Craft
> CMS, proxied by Cloudflare), the web app moved to **`app.chattr.at`** (grey,
> Let's Encrypt), and both old hosts redirect with 301:
> `chattr.geraldhofbauer.net` → `chattr.at` (except `/download/*`, which carries
> the maintenance flag and the old update manifest) and
> `app.chattr.geraldhofbauer.net` → `app.chattr.at` (plus a self-retiring
> service worker, see `scripts/netcup/caddy/app.chattr.geraldhofbauer.net.Caddyfile`).
> **DNS moved to Cloudflare** after all (zone `chattr.at`, `cf` script), so the
> "DNS stays at Netcup / no Cloudflare" rule below is outdated. Phases 2 and 3
> (admin, **API**) have not started: `api.chattr.geraldhofbauer.net` is still
> baked into every client.
>
> FALLE learned in Phase 1: the Cloudflare origin cert for chattr.at covers
> `*.chattr.at`, so Caddy skipped automatic HTTPS for `app.chattr.at` and served
> that cert. Fix: global option `auto_https ignore_loaded_certs` plus
> `tls { issuer acme }` in the site block. Any further grey `*.chattr.at` host
> (e.g. `api.chattr.at`) needs the same, or a narrower origin cert.
>
> **Original status line:** not started. This document is the migration plan for moving Chattr
> off the `*.chattr.geraldhofbauer.net` subdomains onto its own domain
> **`chattr.at`**. Nothing here has been executed. Do a careful, phased cutover
> — **never** a single DNS swap (deployed mobile clients have the backend host
> baked into the binary). Verify every "current state" claim against the live
> servers before acting; this plan was written from notes.

## Why

Move Chattr to its own domain so the project is cleanly separated from the
`geraldhofbauer.net` portfolio, and so everything can live under a single
wildcard `*.chattr.at` with Caddy auto-HTTPS — no more per-subdomain SSL
juggling.

## Ground rules (decided)

- **DNS stays at Netcup.** `chattr.at` was bought at Netcup (same provider as the
  backend VPS in Vienna). **No Cloudflare for this project** (explicit) — do
  **not** use the `cf` script / Cloudflare nameservers. Manage records in the
  Netcup DNS panel.
- **Caddy on the Netcup VPS** terminates TLS and does auto-HTTPS. A wildcard
  `*.chattr.at` cert needs an ACME **DNS-01** challenge (Netcup DNS provider
  plugin for Caddy), or fall back to per-host certs via HTTP-01 (simpler, one
  cert per hostname — fine to start).
- **The backend host is baked into every deployed client** → the API cutover
  must be **dual-host**, never a swap. Old host keeps serving until old builds
  age out.

## Hostname mapping

| Purpose | Today (`geraldhofbauer.net`) | Target (`chattr.at`) | Criticality |
|---|---|---|---|
| Backend / Supabase (Kong) | `api.chattr.geraldhofbauer.net` | `api.chattr.at` | **Critical — baked into clients** |
| Landing page (web) | `chattr.geraldhofbauer.net` | `chattr.at` / `www.chattr.at` | Low (server-rendered, no client bake) |
| Web app | `app.chattr.geraldhofbauer.net` | `app.chattr.at` | Low |
| Admin console | `admin.chattr.geraldhofbauer.net` | `admin.chattr.at` | Low (operator-only, mTLS) |
| Staging admin | `staging-admin.chattr.geraldhofbauer.net` (IONOS) | — leave as-is | n/a |
| APK download | `geraldhofbauer.net/files/chattr-android` | `chattr.at/download` (or keep) | Medium (see below) |

## Phased cutover (safe order: least → most client-coupled)

### Phase 0 — Prep (no user-visible change)
1. In Netcup DNS: add `A`/`AAAA` for `chattr.at`, `www`, `app`, `admin`, and a
   wildcard `*.chattr.at`, all → the Netcup VPS IP. (Keep the old
   `*.chattr.geraldhofbauer.net` records untouched.)
2. Decide wildcard-cert vs per-host. If wildcard: install a Netcup-DNS Caddy
   build (`xcaddy` with the Netcup DNS module) and supply Netcup API creds as
   **env-only** secrets on the box.
3. Add the new hostnames to the Caddyfile **alongside** the old ones (Caddy
   happily terminates both). Reload; confirm certs issue for the new names.

### Phase 1 — Landing + web app (uncritical, do first)
1. Point the landing pipeline / rsync target at the `chattr.at` docroot (or have
   Caddy serve the same root for both names).
2. Serve the web app at `app.chattr.at`. The web app reads its backend URL from
   its build `.env`; rebuild it against **whatever API host is live at the time**
   (still `api.chattr.geraldhofbauer.net` until Phase 3).
3. Set up 301 redirects `chattr.geraldhofbauer.net → chattr.at` and
   `app.chattr.…→ app.chattr.at` for humans/bookmarks. Update the landing page's
   own internal links and the `#technik`/flow content if they hardcode the old
   host.

### Phase 2 — Admin console
1. Serve `admin.chattr.at` via the same Caddy admin block (mTLS + basic_auth,
   see `docs/ADMIN_DASHBOARD.md`). Reissue/extend the mTLS CA SAN if pinned.
2. Update DNS notes; the admin panel is operator-only so there's no client bake.

### Phase 3 — Backend API (**dual-host, last, most careful**)
1. Make Caddy serve **`api.chattr.at` in addition to** `api.chattr.geraldhofbauer.net`,
   both proxying to the same Kong upstream. Verify TLS + a real login/round-trip
   on the new host.
2. Flip the **client** default backend host to `api.chattr.at`:
   - Flutter `.env` (`SUPABASE_URL`, `SUPABASE_ANDROID_URL`) → new host, rebuild.
   - iOS (Mac scope): `.env` backend host **and** Associated Domains /
     `applinks:` entitlement for Universal Links → new domain.
3. Ship new builds (Android APK channel + TestFlight/App Store). **Keep the old
   `api.` host alive** until the overwhelming majority of installs are on a
   build that speaks `chattr.at`. There is no server-side way to force-migrate a
   client that has the old host compiled in — only attrition + a new install.
4. Only after old builds have aged out (months): retire the old `api.` host.

### Phase 4 — APK download
Either move to `chattr.at/download` (update `scripts/deploy-apk-homepage.sh`
target + the Craft download entry, see `docs/`/memory `homepage-apk-deploy`), or
keep it on the portfolio site. If moved, add a redirect from the old path.
**Note:** the standing versionCode/upload-key rules for the APK channel still
apply unchanged (`--split-per-abi arm64`, versionCode `20xx`, upload key
`7f28…146b`, verify the served file with `aapt2`).

## Rollback

Each phase is independently reversible while both hostnames are live:
- Phases 1–2: repoint DNS / Caddy back; the old names never stopped working.
- Phase 3: because it's dual-host, "rollback" is just shipping a build that
  targets the old host again — but old clients were never broken, so a full
  rollback is rarely needed. **Do not** remove the old `api.` host until
  attrition is done.

## Ownership

- **Linux (lead):** Netcup DNS, Caddyfile, landing/web pipeline, APK channel.
- **Mac (Apple scope):** iOS `.env` backend host + Associated Domains / Universal
  Links entitlement, new signed builds — via PR against `main`.
