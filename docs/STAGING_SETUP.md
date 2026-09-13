# Chattr Staging-Environment — Setup-Runbook

Persistentes Staging (`staging-app` / `staging-api.chattr.geraldhofbauer.net`) mit
**eigenem Supabase-Stack** auf demselben VPS wie Prod. Zweck: DAST-Ziel für den
wöchentlichen ZAP-Scan (siehe `SECURITY_SCAN_SETUP.md`, Phase B) — und ein echtes
Test-Environment, das manuelles Testen erlaubt, ohne Prod-Daten zu berühren.

> **Warum ein zweiter kompletter Supabase-Stack:** ZAP darf nie gegen Prod laufen.
> Ein Staging-Frontend allein reicht nicht — es würde am Ende das Prod-Backend
> scannen. Also braucht Staging ein **eigenes** Backend mit **eigenen** Keys/DB.

## Architektur

```
staging-app.chattr…  ─nginx→ /home/chattr/staging/web        (statisches Flutter-Web)
staging-api.chattr…  ─nginx→ 127.0.0.1:8110 (staging-kong)   (eigener Supabase-Stack)
                                    │
                     /home/chattr/staging/supabase/  (docker compose, project chattr_staging)
```

Prod bleibt in `/home/chattr/app/…` unberührt. Staging läuft auf **derselben
Docker-Engine** → Container-Namen + Ports müssen isoliert sein (siehe Gotchas).

## Status (verifiziert 2026-07-14)
**Staging läuft.** Isolierter Supabase-Stack (13 Container, `chattr_staging`) live,
45 Migrationen angewandt, `https://staging-api…` = 200, `https://staging-app…` = 200
(TLS grün), Prod nachweislich unberührt. Zwei Stolpersteine beim Bring-up:
- **Port 8100 war belegt** → Staging-Kong auf **8110** (https 8153, analytics 4110).
- **`migrations/.migration_history`** wurde beim rsync aus Prod mitkopiert und ließ
  `migrate` alle 45 als „applied" überspringen (leere Staging-DB). **Fix:** die Datei
  vor `migrate` löschen bzw. beim rsync ausschließen (`--exclude='.migration_history'`).

Der **Web-Build läuft dauerhaft über die Pipeline** (`deploy-staging`, siehe Schritt E) —
der initiale Seed erfolgte einmalig manuell und wird vom ersten Pipeline-Deploy ersetzt.

## Owner-Legende
`[✓ AUTO]` von Linux-Claude bereits erledigt · `[GERRY sudo]` braucht root ·
`[SUPERVISED]` Gerry führt auf dem VPS aus, Claude schaut auf den Output ·
`[CLAUDE]` Claude erledigt (nach Phase-A-Merge).

---

## Schritte

### A. DNS `[✓ AUTO]`
`staging-app` + `staging-api.chattr.geraldhofbauer.net` A-Records → `<staging-host-ip>`
(unproxied, wie `app.chattr`) sind via `cf dns-set` angelegt.

### B. Staging-Secrets + `.env` `[SUPERVISED]`
Frische, **eigene** Keys (nie Prod-Keys wiederverwenden). Reuse des vorhandenen
Generators:
```bash
# auf dem VPS als chattr, in /home/chattr/staging/supabase/
cp -r ~/app/supabase/* .                 # Stack-Struktur von Prod als Basis
cp <repo>/supabase-docker/.env.example .env  # oder Prod-.env als Vorlage, dann ANpassen
sh <repo>/supabase-docker/utils/generate-keys.sh   # generiert JWT_SECRET/ANON/SERVICE/…
# generierte Werte in .env eintragen (das Skript bietet interaktiv an, .env zu patchen)
```
Danach in `.env` **staging-spezifisch** setzen:
```
SITE_URL=https://staging-app.chattr.geraldhofbauer.net
API_EXTERNAL_URL=https://staging-api.chattr.geraldhofbauer.net
SUPABASE_PUBLIC_URL=https://staging-api.chattr.geraldhofbauer.net
POSTGRES_PORT=5432            # INTERN lassen (Connection-Strings) — Publishing macht der Transform
KONG_HTTP_PORT=8000           # intern; extern published der Transform auf 8110
```
> **Secrets NIE in einen Chat/Transkript kopieren.** Sie leben nur in dieser `.env`
> auf dem VPS (+ als BB-Var `STAGING_ENV`, Schritt E). ANON_KEY ist öffentlich
> (im Web-Build), SERVICE_ROLE_KEY/POSTGRES_PASSWORD bleiben geheim.

### C. Staging-Supabase hochfahren `[SUPERVISED]`
Isolierten Compose erzeugen (prefixt Container-Namen, remappt Ports → siehe Gotchas):
```bash
# in /home/chattr/staging/supabase/
<repo>/scripts/staging/make-staging-compose.sh docker-compose.yml > docker-compose.staging.yml
export COMPOSE_PROJECT_NAME=chattr_staging
docker compose -f docker-compose.staging.yml up -d
docker compose -f docker-compose.staging.yml run migrate
# Edge-Functions in den Runtime-Ordner spiegeln (wie im Prod-Deploy)
mkdir -p volumes/functions && rsync -a --exclude=tests functions/ volumes/functions/
docker compose -f docker-compose.staging.yml restart functions
```
Claude schaut auf den Output — Port-/Namens-Kollisionen erscheinen hier sofort und
werden gemeinsam iteriert (Prod bleibt dabei unberührt, Docker verweigert nur den
Staging-Start bei Kollision).

### D. nginx + TLS `[GERRY sudo]`
```bash
sudo bash <repo>/scripts/staging/setup-nginx-staging.sh
```
Legt beide vhosts an (`staging-app` statisch, `staging-api` → `127.0.0.1:8110` mit
WS-Upgrade für Realtime) und holt Let's-Encrypt-Zerts via certbot.

### E. Deploy-Automatik + BB-Vars `[CLAUDE nach Phase-A-Merge]` / `[GERRY]`
- `[GERRY]` BB-Repo-Vars setzen:
  - `STAGING_ENV` (secured) = kompletter `.env`-Inhalt der Staging-Supabase
    (`bb var-set STAGING_ENV "$(cat .env)"` — Wert nie ins Transkript).
  - `STAGING_SUPABASE_URL` = `https://staging-api.chattr.geraldhofbauer.net`
  - `STAGING_SUPABASE_ANON_KEY` = der Staging-ANON_KEY (öffentlich).
  - `STAGING_URL` = `https://staging-app.chattr.geraldhofbauer.net` (schaltet ZAP scharf).
- `[CLAUDE]` `deploy-staging` custom-Pipeline-Step ergänzen (baut Web gegen die
  Staging-Vars, rsynct Stack + `STAGING_ENV` → `.env`, `docker compose up`/`migrate`,
  rsync Web nach `/home/chattr/staging/web`). Wird **nach** dem Phase-A-Merge in
  `bitbucket-pipelines.yml` eingehängt (sonst `custom:`-Merge-Konflikt mit Phase A).
- `[GERRY]` einmal triggern: `bb run main --pattern deploy-staging`.

### F. ZAP scharf `[✓ nach E]`
Sobald `STAGING_URL` gesetzt ist, scannt der wöchentliche `weekly-full-security-scan`
automatisch `https://staging-app…` (der ZAP-Step self-skippt nur ohne die Var).

---

## Gotchas (wichtig)
- **Shared Docker-Engine:** Prod-Compose nutzt feste `container_name:` + published
  Ports. `make-staging-compose.sh` prefixt alle Namen mit `staging-` und bindet die
  published Ports auf `127.0.0.1` (kong 8110/8153, db 5532, pooler 6643, analytics
  4110). **Immer** diesen Transform nutzen, nie den Prod-Compose direkt.
- **`POSTGRES_PORT` ist intern UND published:** in `.env` auf `5432` lassen (interne
  Connection-Strings), der Transform published extern auf `5532`. Nicht in `.env`
  umbiegen, sonst brechen die DB-URLs.
- **Zweite Attack-Surface:** Staging ist ein weiteres öffentliches Backend. `.env`
  strikt `chmod 600`, `DISABLE_SIGNUP` nach Bedarf, keine Prod-Daten importieren.
- **Kein `chattr@`-SSH für Claude:** VPS-Schritte laufen über Gerry bzw. die Pipeline
  (die hat den `chattr@`-Key). Deshalb sind B/C/D supervised bzw. sudo.

## Verifikation
1. `https://staging-app.chattr.geraldhofbauer.net` lädt die Web-App (TLS grün).
2. Registrierung/Login geht gegen **Staging**-Supabase (`staging-api…`), nicht Prod.
3. `docker compose -f docker-compose.staging.yml ps` → alle Container `healthy`,
   Prod-Container unverändert (`docker ps | grep -v staging-`).
4. Prod-Gegencheck: Prod-DB-Row-Counts unverändert (eigenes Volume/Keys).
5. Weekly-Scan triggern → ZAP-Report für `staging-app` als Artefakt + in der
   pipepush-Summary.
