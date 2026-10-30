# Netcup-Migration — Skript-Suite

Ausführungs-Skripte für den Umzug des Chattr-Backends auf den Netcup-VPS (Wien).
**Gerry führt aus** (SSH-Prod ist für Linux-Claude geblockt). Plan-Kontext: `docs/NETCUP_MIGRATION.md`.

## Server-Wahl
**VPS 1000 G12** (4 vCores / 8 GB / 256 GB NVMe, ~10 €/Mon, Standort **Wien**).
Volle Supabase-Compose + **4 GB Swap** (kein Analytics-Trim — `analytics` ist per `depends_on`
tief verdrahtet; Swap ist robuster und wartungsfrei).

## Migrations-Ansatz: Volume-level Lift-and-Shift
Prod und Netcup fahren dieselbe Postgres-Image-Version (`supabase/postgres:15.8.1.085`) → das
rohe PGDATA + Storage-Volume werden **1:1 kopiert** (tar mit `--numeric-owner`, als root). Das ist
faithful und umgeht pg_restore-Rollen/Schema-Konflikte. Ein logischer `pg_dump` wird trotzdem als
**Rollback-Backup** gezogen.

## Reihenfolge
| # | Skript | Wo | Wann |
|---|---|---|---|
| 1 | `01-provision-netcup.sh` | **Netcup** (root/sudo) | Vorlauf, nach Bestellung |
| — | `nginx/*.conf` + certbot | **Netcup** (sudo) | Vorlauf (Cert per DNS-01 vorziehen) |
| 2 | `02-cutover-dump-prod.sh` | **Prod** (Gerry) | Wartungsfenster: Stop + Dump + Volumes packen |
| 3 | `03-restore-up-netcup.sh` | **Netcup** (Gerry) | Wartungsfenster: Volumes rein + `up` + `migrate` |
| 4 | `04-verify.sh` | egal | nach `up`: Health/Row-Counts/Media/Realtime |
| — | DNS-Flip `api./app./chattr.` → Netcup-IP | DNS-Panel | nach grünem verify |

## Kritische Constraints (nicht verhandelbar)
1. **Hostname `api.chattr.geraldhofbauer.net` bleibt** → nur DNS-A-Record umziehen, KEIN App-Rebuild.
2. **`.env` 1:1 kopieren** (JWT_SECRET/ANON_KEY/SERVICE_ROLE_KEY/POSTGRES_PASSWORD/VAULT_ENC_KEY…) —
   Anon-Key ist in jeden Client eingebacken; neu generieren = Totalausfall.
3. **nginx `client_max_body_size 500m`** auf dem api-Vhost (sonst werden große Media/Chunks abgewiesen).
4. **TLS-Cert für `api.chattr…` VORAB per DNS-01** auf Netcup ausstellen (während A-Record noch auf
   Prod zeigt) → Cutover ohne Cert-Lücke.

## Downtime-Optimierung
Das **Storage-Volume vorab live** rübersyncen (Objekte sind write-once, werden nur gelöscht) und im
Fenster nur ein **Delta-rsync** fahren → Fenster ≈ DB-Größe. DB muss im Fenster gestoppt getart werden.
