# Chattr-Backend → Netcup (Wien) — Migrationsplan

> Status: **VORBEREITUNG** (Netcup-Server existiert noch nicht). Ausführung erst nach
> Server-Provisionierung + Gerrys Freigaben (offene Punkte unten). Kein Cutover ohne
> frisches Backup + Rollback-Punkt.

## Ziel
Nur **Chattr** vom geteilten Prod-Server (`gerry@<staging-host>` — teilt sich die Box mit
Passbolt, geraldhofbauer.net u.a.) auf einen **eigenen Netcup-Server in Wien** auslagern
(Latenz + Datenschutz AT). Lift-and-Shift des kompletten Self-hosted-Supabase-Stacks.

## Was migriert wird (Inventar)
| Komponente | Ort heute | Migration |
|---|---|---|
| Supabase-Stack | `~/app/supabase/docker-compose.yml` (10 Services) | Compose 1:1 neu hochziehen |
| Postgres-Daten | `~/app/supabase/volumes/db/data` | **DB-Dump** (`pg_dump`/`pg_dumpall`) → Restore |
| Media (E2E-Ciphertext) | `~/app/supabase/volumes/storage` (File-Backend, kein S3) | **rsync** des Volumes |
| Secrets | `~/app/supabase/.env` (NICHT im Repo) | **1:1 kopieren** (s. Constraint) |
| Edge Functions | `~/app/supabase/functions` → `volumes/functions` | via Repo-Deploy (kommen aus Git) |
| FCM Service Account | `~/app/supabase/.fcm_sa.json` | kopieren |
| Web-App + Landing | `~/app/web`, `~/app/landing` | via Repo-Deploy (statische Files) |
| Host-nginx + TLS | `/etc/nginx/sites-enabled/*`, certbot | auf Netcup **neu** aufsetzen |

## Kritische Constraints (Datensicherheit / kein Client-Bruch)
1. **Hostname bleibt `api.chattr.geraldhofbauer.net`.** Deployte Mobile-Clients (iOS/Android/Galaxy)
   haben diese URL fest im Build. Migration = **DNS-A-Record auf neue Netcup-IP**, KEIN App-Rebuild.
   Ebenso `app.chattr…` / `chattr.geraldhofbauer.net` (Web/Landing).
2. **Supabase-`.env` verbatim übernehmen** — v.a. `JWT_SECRET`, `ANON_KEY`, `SERVICE_ROLE_KEY`,
   `POSTGRES_PASSWORD`. Der **Anon-Key ist in jeden Client eingebacken**; neuer JWT-Secret = alle
   Bestands-Tokens/Anon-Keys ungültig → Totalausfall. Also NICHT neu generieren.
3. **E2E-Datenlage:** Server hält nur **Ciphertext bis Delivery** (wird nach mark_message_received
   gelöscht). Private Keys liegen nur auf den Geräten → kein Server-seitiger Schlüssel-Verlust
   möglich. Migrationsrisiko = **in-flight Nachrichten** (noch nicht zugestellt) + Storage-Objekte
   (noch nicht abgeholte Media) + Realtime-Kontinuität. Deshalb Dump/rsync **im Wartungsfenster**
   (Schreibstopp), nicht live.
4. **FILE_SIZE_LIMIT 500 MiB** muss überall konsistent bleiben: `config.toml` +
   `docker-compose.yml` (FILE_SIZE_LIMIT=524288000) + **nginx `client_max_body_size`** am neuen Host
   (sonst werden große Media/Chunks am neuen nginx abgewiesen — siehe `media_repository.dart`).

## Cutover-Strategie (empfohlen: kurzes Wartungsfenster)
E2E + ephemere Nachrichten machen ein kurzes Fenster unkritisch (kein „near-zero" nötig):

**Vorlauf (Tage vorher, ohne Downtime):**
1. Netcup-Server (Wien) provisionieren, Docker + docker-compose, `chattr`-User (docker-Gruppe),
   nginx + certbot installieren, Firewall (nur 80/443 + SSH).
2. Stack-Grundgerüst nach `/home/chattr/app/` bringen (Repo-Deploy-Pfad beibehalten → Pipeline
   muss nur `SERVER_ADDR` + Deploy-SSH-Key tauschen).
3. **DNS-TTL runtersetzen** auf 60–300 s für die chattr-Subdomains (schneller Cutover-Rollback).
4. **Test-Restore** eines Prod-Backups auf Netcup (Dump importieren, Stack hochfahren, gegen eine
   Test-Subdomain wie `nc.chattr.geraldhofbauer.net` verifizieren) — Migration einmal trocken üben.

**Cutover (Wartungsfenster, ~15–30 min):**
5. Prod: **Schreibstopp** (Stack stoppen oder in read-only; Clients kurz offline — Realtime rebubbelt).
6. **Finaler Dump** (`pg_dumpall` bzw. `pg_dump` der Chattr-DB) + **finaler `rsync`** von
   `volumes/storage` → Netcup.
7. Netcup: Restore DB + Storage, `.env`/`.fcm_sa.json` einspielen, `docker compose up -d` +
   `docker compose run migrate` + `functions` restart, Vault-Secrets (`service_role_key`,
   `project_url`) prüfen (Pipeline-Schritt existiert).
8. **certbot** für alle chattr-Subdomains am Netcup-Host (DNS muss zeigen — ggf. DNS-01 vorab).
9. **DNS umstellen:** A-Records `api./app./(chattr).chattr.geraldhofbauer.net` → neue Netcup-IP
   (überschreibt den `*.geraldhofbauer.net`-Wildcard auf <staging-host> durch spezifischere Records).
10. **Verifizieren:** `curl https://api.chattr…/auth/v1/health`, Login/Realtime mit echtem Client
    (Galaxy), Media-Send/Receive, Push (FCM). Entry-/Row-Counts vor/nach vergleichen.
11. **Rollback-Punkt:** DNS zurück auf alte IP + alten Stack wieder starten (deshalb TTL niedrig).

**Nachlauf:**
12. Bitbucket-Prod-`SERVER_ADDR` + Deploy-SSH-Key auf Netcup umstellen; ein Test-Deploy fahren.
13. Alten Chattr-Stack auf <staging-host> erst nach ein paar Tagen stabiler Beobachtung abbauen
    (Storage-Volume als Backup behalten).

## Offene Punkte (brauchen Gerry-Entscheidung — VOR Provisionierung)
- [ ] **Server-Specs** (RAM/CPU/Disk) — Postgres + Storage-Volume-Größe = aktuelle Prod-Nutzung
      (Gerry: `du -sh volumes/db/data volumes/storage` am Prod). Netcup-Wien-Produktlinie?
- [ ] **Naming** von Server/Ressourcen — NIE selbst benennen (CLAUDE.md-Regel). Gerry fragen.
- [ ] **DNS-Kontrolle:** wo wird `geraldhofbauer.net` verwaltet? (`cf`-Tool deckt nur gh.gallery/
      ghgallery.app.) Wildcard `*.geraldhofbauer.net → <staging-host>` existiert → wir brauchen
      spezifische A-Records fürs Chattr. Zugang/Provider klären.
- [ ] **Runner-Box wiederverwenden?** Es läuft schon ein Netcup-VPS als self-hosted BB-Runner
      ([[bb-self-hosted-runner-ssh-keys]]). Eigener Box für User-Daten-Backend (Isolation) empfohlen
      statt Mitnutzung — Gerry entscheidet.
- [ ] **SSH-Zugang für mich (Linux-Claude):** aktuell ist SSH auf Prod klassifikator-geblockt →
      Dump/rsync/Cutover-Schritte muss Gerry per `!`/on-server fahren; ich liefere fertige Skripte.
- [ ] **Wartungsfenster** terminieren (nachts, wenig Traffic).
- [ ] **Staging mitnehmen?** (`staging-api./staging-app.chattr…`) oder auf altem Server lassen.

## Entscheidungen (2026-07-22, mit Gerry)
- **Server: VPS 1000 G12** (4 vCores / 8 GB / 256 GB NVMe, ~10 €/Mon, **Wien**) — Gerry kauft.
  Reicht: Chattr bekommt die *ganze* Box (heute teilt es sich Prod mit Passbolt/geraldhofbauer.net).
- **KEIN Analytics-Trim.** `analytics`/logflare ist per `depends_on` in 8 Services verdrahtet →
  Trim wäre fragil + würde beim Repo-Deploy überschrieben. Stattdessen **volle Compose + 4 GB Swap**.
- **Migrations-Ansatz: Volume-level Lift-and-Shift** (gleiche Postgres-Image-Version
  `supabase/postgres:15.8.1.085`) → rohes PGDATA + Storage per `tar --numeric-owner` (uid-treu, als
  root) 1:1 kopieren. Umgeht pg_restore-Rollen/Schema-Konflikte. Logischer `pg_dump` nur als Rollback.

## Skript-Suite (fertig, in `scripts/netcup/`)
- `01-provision-netcup.sh` — Netcup (root): Docker/compose, nginx, certbot, ufw, `chattr`-User, 4 GB Swap.
- `02-cutover-dump-prod.sh` — Prod (Gerry): Safety-pg_dump → `compose down` → PGDATA+Storage taren → Transfer.
- `03-restore-up-netcup.sh` — Netcup: Volumes rein → `compose up` → `migrate` (no-op) → Vault-Secrets.
- `04-verify.sh` — Health/Row-Counts/Media/Realtime.
- `nginx/*.conf` — Vhosts api/app/landing (WebSocket-Upgrade für Realtime, `client_max_body_size 500m`).
- `README.md` — Reihenfolge + welche Box.
- Alle laufen bei **Gerry** (SSH-Prod für mich geblockt).

Siehe globale CLAUDE.md (Deployment-Konventionen), [[backlog-chattr-netcup-migration]],
[[bb-self-hosted-runner-ssh-keys]], [[prod-e2e-validated]].
