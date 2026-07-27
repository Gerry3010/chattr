# Changelog

Alle nennenswerten Änderungen an diesem Projekt werden in dieser Datei dokumentiert.

Das Format basiert auf [Keep a Changelog](https://keepachangelog.com/de/1.0.0/),
und dieses Projekt folgt [Semantic Versioning](https://semver.org/lang/de/).

## [Unreleased]

### Infrastruktur & Rechtliches
- **AGPL-3.0-Lizenzierung**: LICENSE + SPDX-Header projektweit
- **Wöchentliche Security-Scan-Pipeline**: Semgrep (SAST) + Trivy (Deps) + govulncheck (Go-CVEs) + OWASP ZAP (DAST gegen Staging) → pipepush-Benachrichtigung
- **Persistentes Staging-Environment** (eigener isolierter Supabase-Stack auf dem VPS)
- Landing: ehrliche Open-Source-Formulierung „Open Source (AGPL-3.0)" (Landing 1.1.2)

## [1.2.0] - 2026-07-13

### Release Notes
Post-Quantum-Verschlüsselung (X25519 + ML-KEM-768), E2E-Medien (Foto/Video/Audio/Dateien), Recovery-Phrase + Backup-Datei, MCP-Agent-Chats, Nachrichten-Aktionen (Reaktionen mit Push, Antworten, Weiterleiten, Bearbeiten, Zurückrufen, Timer), Blockieren, Username ändern, Link-Vorschauen mit Popup-Player, Android-Share-Target — plus zahlreiche Fixes.

### Added
- 🔐 **Post-Quantum-Hybrid-Verschlüsselung**: X25519 + ML-KEM-768 (KEM/DEM) ersetzt RSA-2048; jede Nachricht einzeln pro Empfänger verschlüsselt
- 📎 **E2E-Medien**: Fotos, Videos, Audio & Dateien (privater Bucket, clientseitig verschlüsselt); Inline-Bild/Audio/Video-Player; gzip vor Verschlüsselung; Composer-Paste (Ctrl/Cmd+V)
- 🔑 **Recovery-Phrase** (BIP39 → Ed25519 Challenge-Response) + **Backup-Datei** zum Identitäts-Restore
- 🤖 **MCP-Agent-Chats**: token-gebundene Owner-Sichtbarkeit, globale Registrierung, cross-project Chat-Registry, Realtime-`chattr_wait`
- 💬 **Nachrichten-Aktionen**: einheitliches Menü, Reaktionen (mit Push + Wer-hat-reagiert-Sheet), Antworten, Weiterleiten, Bearbeiten, „Für alle löschen", selbstzerstörende Timer, Enter-to-send
- 🧑 Username/Anzeigename ändern; Token-Revoke entzieht Agenten den Chat-Zugriff
- 🚫 Nutzer blockieren (1:1, DB-durchgesetzt); server-seitiges Chat-Mute mit Datum/Zeit
- 🔗 Rich-Link-Vorschauen (YouTube/Reddit-Thumbnails + og:image) + In-App-Popup-Player
- 📥 Android-Share-Target (Text & Dateien empfangen)
- 🖼️ Avatare, Screenshot-Schutz (Android), Chat-Beschreibung, QR-Manual-Join, Key-Rotation
- 🌐 Landing „Technik"-Sektion (alle App-Flows als Mermaid-Diagramme)

### Fixed
- Zeitstempel in Geräte-Lokalzeit (Transport/Storage bleibt UTC); zwei Server-Write-Offset-Bugs
- System-Nachrichten (Hybrid-KEM) wiederhergestellt + konsistente Formatierung; Key-Rotation angekündigt
- Resync von Nachrichten & Unread-Badges bei App-Resume; Share-Target-Dispose-Crash
- Link-Preview: offener SSRF-Proxy geschlossen (In-Function-Auth-Gate)
- i18n: chatview-Package-Strings lokalisiert; grammatikalisch korrekte deutsche Labels

### Security
- **Post-Quantum-sichere** Ende-zu-Ende-Verschlüsselung (X25519 + ML-KEM-768) ersetzt RSA-2048
- Link-Preview-Edge-Function: SSRF-Guard + In-Function-JWT-Gate (self-hosted Runtime verifiziert keine JWTs)

## [1.1.2] - 2026-07-10

### Release Notes
Dark-Mode-Wallpaper (Matrix/Ozean/Sonnenuntergang/Königlich/Rose); Chat-Fixes: Membership-Banner flackert nicht mehr, Message-Grouping mit korrektem Bubble-Einzug und Absendername pro Gruppe


## [1.1.1] - 2026-07-10

### Release Notes
Android-Fix (Biometrie/FlutterFragmentActivity: Chats+Messages entschlüsseln jetzt), 5 neue Light-Themes mit Foto-Wallpapern, QR-Manual-Join-Fixes, Push-Token-Persistenz


## [1.1.0] - 2026-07-10

### Release Notes
Unified message menu with quick reactions, reply/forward/edit/unsend fixes, reaction priming, honest chat delete, compact link previews, timed per-chat mute with date/time picker, QR manual code entry, theme-aware reply views, web push de-duplication (data-only FCM), upload retry + size guard, PWA auto-updater


### Added
- Versioning-System für alle Komponenten (Client, Backend, Landing Page)
- Version-Kompatibilitätsprüfung zwischen Client und Backend
- Automatisierte Release- und Version-Bump-Scripts
- Supabase Version-Tracking Tabelle

## [1.0.0] - 2026-04-04

### Added
- 🔐 End-to-end Verschlüsselung mit RSA-2048
- 🔑 Anonyme Authentifizierung (kein Email erforderlich)
- 🗑️ Automatische Nachrichtenbereinigung nach dem Lesen
- 💬 Echtzeit-Messaging mit Gruppen- und Einzelchats
- 👥 Admin-System mit Mitgliederverwaltung
- ✓ Lesebestätigungen für Nachrichten
- 📱 QR-Code Sharing für Kontakte und Chats
- 🌍 Multi-Language Support (Deutsch/Englisch)
- 🔔 Push-Benachrichtigungen (FCM)
- 🔄 Offline-Support mit lokaler verschlüsselter Speicherung
- 📊 Chat-Metadaten (Unread Counts, Last Message)
- 🗨️ System-Nachrichten für Membership-Events

### Security
- RSA-2048 Verschlüsselung für alle Nachrichten
- Verschlüsselter lokaler SQLite-Speicher
- Row Level Security (RLS) für alle Supabase-Tabellen
- Sichere Key-Verwaltung mit flutter_secure_storage

### Infrastructure
- Flutter 3.10.4+ App (Android, iOS, Web, Desktop)
- Supabase Backend mit Realtime
- Docker-basierte Supabase-Entwicklungsumgebung
- Bitbucket Pipelines CI/CD
- VPS Deployment mit rsync
