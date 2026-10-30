<!--
SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Nächtliche Sicherung (CHAT-26)

Bisher entstand eine Sicherung nur vor einem Server-Deploy und lag auf derselben
Box wie die Datenbank. Diese beiden Skripte holen jede Nacht eine verschlüsselte
Sicherung auf eine zweite Box.

| Skript | Läuft auf | Tut |
|---|---|---|
| `chattr-backup-export.sh` | Prod, als Besitzer des Compose-Stacks | Dump + `.env` + TURN-Secret (+ optional Storage) als **ein** age-verschlüsseltes Archiv auf stdout |
| `chattr-backup-pull.sh` | Backup-Box, per cron | holt das Archiv über einen eigenen SSH-Schlüssel, prüft es, behält die letzten 14, meldet über pipepush |

Verschlüsselt wird mit einem age-**Empfängerschlüssel**. Auf Prod liegt nur der
öffentliche Teil, der private liegt offline. Weder Prod noch die Backup-Box kann
alte Sicherungen lesen.

## Einrichten (einmalig, ohne sudo außer der Paketinstallation)

1. **age** installieren (Prod: zum Verschlüsseln, Rechner zuhause: zum Entschlüsseln).
2. **Schlüsselpaar** zuhause erzeugen: `age-keygen -o chattr-backup.key`. Den
   privaten Schlüssel in den Passwortmanager legen, die Zeile `public key: age1…`
   notieren.
3. **Prod**, als Besitzer des Stacks:
   - Skript nach `~/bin/chattr-backup-export.sh`;
   - `~/.config/chattr-backup/export.env` (0600) mit
     `CHATTR_AGE_RECIPIENT=age1…`;
   - in `~/.ssh/authorized_keys` den öffentlichen Abholschlüssel **mit** Zwang:
     `command="$HOME/bin/chattr-backup-export.sh",no-pty,no-port-forwarding,no-agent-forwarding,no-X11-forwarding ssh-ed25519 AAAA… chattr-backup-pull`
4. **Backup-Box**:
   - `ssh-keygen -t ed25519 -f ~/.ssh/chattr_backup_pull -N ''`;
   - Skript nach `~/bin/`, `~/.config/chattr-backup/pull.env` (0600) mit
     `CHATTR_BACKUP_HOST=<user>@<prod-host>`;
   - pipepush-Token für Projekt `chattr`, Pipeline `backup`, nach
     `~/.config/chattr-backup/token` (0600);
   - cron: `40 3 * * * $HOME/bin/chattr-backup-pull.sh >> $HOME/backups/chattr/pull.log 2>&1`
5. **Einmal wiederherstellen üben**: Archiv entschlüsseln
   (`age -d -i chattr-backup.key chattr-….tar.age | tar -x`), Dump in die lokale
   Supabase einspielen, Zählungen gegen Prod halten.

## Was es meldet

- Bei jedem Fehlschlag sofort (pipepush, Status `failed`).
- Montags eine Zeile als Lebenszeichen mit Größe und Anzahl.
