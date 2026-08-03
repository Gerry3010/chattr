# Security-Scan-Pipeline — Setup & Status

> **Status: Phase A umgesetzt** (Linux-Code-Claude, 2026-07-14). Das ursprüngliche
> Gerüst (von Chat-Claude) war generisch für einen Go-Service geschrieben und wurde
> an die reale Chattr-CI (Bitbucket Pipelines) + die echte pipepush-API angepasst.
> Diese Datei dokumentiert, was tatsächlich gebaut wurde. Gerry entscheidet, ob sie
> ins Repo committet oder gelöscht wird.

## Ziel
Automatisierte Security-Scans in der bestehenden Bitbucket-Pipeline, mit einer
**Pipepush-Benachrichtigung** (Findings-Zusammenfassung) am Ende des wöchentlichen Laufs.

## Was umgesetzt ist (Phase A — live-fähig ohne Staging)

### `bitbucket-pipelines.yml` (in die bestehende Pipeline **gemergt**, Deploy-Flow unangetastet)
- **Pro Push (parallel, non-blocking):** `security-fast` — **Semgrep** SAST
  (`--config=auto`, Dart + Go). Läuft parallel zu `analyze-and-test`, blockiert den
  Deploy nie (`|| true`). JSON + SARIF als Artefakte.
- **Wöchentlich** (`custom: weekly-full-security-scan`, alle Scans parallel):
  - **Semgrep** (SAST) — wiederverwendet `security-fast`.
  - **Trivy** (`fs`, HIGH/CRITICAL) — scannt in einem Pass `pubspec.lock` **und**
    `native/chattr_crypto/go.sum`.
  - **govulncheck** (`golang:1.26`) auf `native/chattr_crypto/` (ML-KEM-768-Kern,
    `cloudflare/circl`). Läuft wöchentlich statt pro Push (Go-CVE-Kadenz; das Modul
    ändert sich selten zwischen Pushes).
  - **OWASP ZAP Baseline** (DAST) — **konditional**: läuft nur, wenn Repo-Var
    `STAGING_URL` gesetzt ist, sonst sauberer Skip. Wird in **Phase B** scharf
    geschaltet (persistentes Staging).
  - **Pipepush-Benachrichtigung** — `scripts/notify_via_pipepush.py`.

### `scripts/notify_via_pipepush.py`
Echte pipepush-API (nicht die Platzhalter `/notify` `/logs`):
`POST $PIPEPUSH_SERVER/api/webhook` mit
`{token, status, pipeline:"security-scan", branch, commit, runId, message}`.
Reuse des bestehenden `PIPEPUSH_TOKEN` (chattr-Projekt) → eigener, klar benannter
Notification-Stream **"security-scan"**. `status="failure"` bei HIGH/CRITICAL-Findings,
sonst `success`. `message` enthält Findings-Zähler je Tool (Semgrep/Trivy/govulncheck/ZAP)
als Log-Ausschnitt. **Keine** Secrets/Nutzerdaten in der Nachricht. Degrade ohne Vars.

### Wöchentlicher Schedule
Über `~/.claude/scripts/bb schedule-create main weekly-full-security-scan` (Default-Cron
`0 0 3 ? * MON *` = Mo 03:00 UTC). Wird nach dem Merge auf `main` angelegt (die custom-
Pipeline muss dafür auf `main` existieren). Alternativ: *Repo Settings → Pipelines →
Schedules*.

## Repository-Variablen
- `PIPEPUSH_SERVER`, `PIPEPUSH_TOKEN` — **existieren bereits** (Deploy-Notify), wiederverwendet.
- `STAGING_URL`, `STAGING_SUPABASE_URL`, `STAGING_SUPABASE_ANON_KEY` — **Phase B** (Staging).

## Phase B (offen, kollaborativ) — persistentes Staging + ZAP scharf
Eigener Supabase-Stack auf dem VPS (`staging-app`/`staging-api.chattr.geraldhofbauer.net`),
nginx-vhost + certbot (root → Gerry per `sudo`), `deploy-staging`-Pipeline-Step, dann
`STAGING_URL` setzen → ZAP läuft gegen Staging (nie gegen Prod). Staging bekommt **eigene**
Keys/DB.

## Abweichungen vom Original-Gerüst (bewusst)
- **Kein Go-Service:** `develop`-Branch entfällt (existiert nicht); `golang:1.23`→`1.26`
  (matcht `go.mod`); `govulncheck` zielt auf `native/chattr_crypto/` statt Repo-Root.
- **Bestehende `bitbucket-pipelines.yml` gemergt**, nicht überschrieben (Deploy bleibt intakt).
- **Echte pipepush-API** statt Platzhalter-Endpoints.
- **ZAP nie gegen Prod** — konditional auf `STAGING_URL`, scharf erst in Phase B.

## Akzeptanzkriterien
- [x] Push triggert Semgrep (schnell, non-blocking, parallel); govulncheck läuft wöchentlich.
- [x] `weekly-full-security-scan` definiert (Semgrep + Trivy + govulncheck + ZAP + Notify).
- [x] ZAP scannt ausschließlich `STAGING_URL`, niemals Prod (self-skip ohne Var).
- [x] Notify-Step ruft die **echte** pipepush-API auf (Platzhalter ersetzt).
- [x] Benachrichtigung enthält Scan-Zusammenfassung (Findings je Tool) als Log-Ausschnitt.
- [x] Keine Secrets/Nutzerdaten in Logs/Benachrichtigung.
- [ ] Schedule in Bitbucket angelegt (nach Merge auf `main`).
- [ ] Phase B: persistentes Staging + ZAP scharf.
