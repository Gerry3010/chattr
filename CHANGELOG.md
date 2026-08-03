# Changelog

Alle nennenswerten Änderungen an diesem Projekt werden in dieser Datei dokumentiert.

Das Format basiert auf [Keep a Changelog](https://keepachangelog.com/de/1.0.0/),
und dieses Projekt folgt [Semantic Versioning](https://semver.org/lang/de/).

## [Unreleased]

## [1.12.0] - 2026-08-03

### Added
- ⏳ **Selbstzerstörung wird jetzt angekündigt**: schaltet jemand die selbstzerstörenden Nachrichten ein oder aus, sehen das alle im Chat als Systemnachricht („Gerry hat die Selbstzerstörung nach 5 Minuten aktiviert"). Bisher änderte sich die Regel für alle, ohne dass es außer der Person selbst irgendwer erfahren konnte. Die Dauer wird als reine Zahl übertragen und auf jedem Gerät in dessen eigener Sprache formuliert
- 🎨 **Systemnachrichten haben Zustände**: statt einer einheitlich grauen Zeile jetzt getönt und mit Symbol — beigetreten/zugelassen grün, verlassen/befördert neutral, **entfernt / neue Schlüssel erzeugt / Selbstzerstörung deaktiviert** gelb (also genau die, die man wirklich lesen sollte), nicht entschlüsselbar rot

### Changed
- 👍 **Reaktionen in 1:1-Chats ohne Profilbilder**: bei zwei möglichen Personen sagt der Kreis neben dem Emoji nichts, was das Emoji nicht schon sagt. Stattdessen erscheint eine Zahl — und die auch erst, wenn beide reagiert haben. In Gruppen bleibt alles wie bisher (Fork p22)

### Fixed
- 💬 Eine Systemnachricht, die diese App-Version noch nicht kennt, zeigt nicht mehr ihren technischen Rohtext (`{action: ...}`) im Chat; eine, die sich nicht entschlüsseln ließ, sagt das jetzt, statt leer zu bleiben

## [1.11.3] - 2026-08-03

### Security & Datenschutz
- 🔒 **Echtzeit-Kanäle sind jetzt privat**: der Benachrichtigungskanal eines Nutzers war öffentlich — wer eine Nutzer-ID kannte, konnte dessen Metadaten-Strom live mitlesen (welcher Chat, wer schreibt, wann; Inhalte blieben verschlüsselt). Der Kanal ist jetzt an das eigene Konto gebunden. *Übergangsweise wird noch zusätzlich auf den alten Kanal gesendet, damit ältere App-Versionen weiterlaufen — dieser Rest wird abgeschaltet, sobald alle aktualisiert haben.*
- 📷 **Profil- und Gruppenbilder werden von Metadaten befreit** (EXIF/GPS): Chat-Medien wurden schon bereinigt, Avatare nicht — sie landeten mit Aufnahmeort, Gerätemodell und Aufnahmezeit im öffentlich lesbaren Bildspeicher. Betrifft besonders direkt mit der Kamera aufgenommene Gruppenbilder
- 🗑️ **Nachrichten-Metadaten verschwinden endlich vollständig**: bei abgeschalteten Lesebestätigungen blieb die (inhaltslose) Datenzeile bisher dauerhaft liegen — ausgerechnet die Datenschutz-Einstellung erzeugte also mehr bleibende Spuren. Jetzt werden sie wie gelesene Nachrichten nach 7 Tagen entfernt
- 💬 Zitat-Vorschau und der darin gespeicherte Absendername werden beim Zustellen mitgelöscht (bisher blieb der Name im Klartext stehen)
- 😀 Reaktionen zu gelöschten Nachrichten werden aufgeräumt (sie überlebten bisher die Nachricht, auf die sie sich bezogen)
- 🧾 Server-Protokolle enthalten keine Nutzdaten mehr: Chat-Namen, Absendernamen, Empfängerlisten und Push-Gerätekennungen wurden mitgeschrieben und dauerhaft gespeichert

### Infrastruktur
- Zugriffsprotokoll des API-Gateways abgeschaltet (es enthielt Chat- und Empfänger-IDs in den Anfrage-URLs) und interne Dienste nur noch lokal erreichbar; Härtungs-Skript `scripts/netcup/harden-log-metadata.sh` (Standard: Trockenlauf)

## [1.11.2] - 2026-08-02

### Fixed
- 📋 iOS: Beim Öffnen des Nachrichtenfeld-Menüs erscheint nicht mehr jedes Mal der Einfügen-Hinweis („Chattr möchte aus … einfügen"). Ob etwas Einfügbares in der Zwischenablage liegt, wird jetzt geprüft, **ohne** den Inhalt zu lesen — der Hinweis kommt nur noch, wenn du tatsächlich auf „Einfügen" tippst. Android/Desktop/Web unverändert

## [1.11.1] - 2026-08-02

### Fixed
- 🎨 Avatar-Initialen jetzt wirklich überall gleich: derselbe Nutzer bekommt auf allen Flächen denselben Buchstaben in derselben Farbe und derselben relativen Größe. Die Buchstabenfarbe wird konsistent nach WCAG-Kontrast gewählt (Chat-Liste, Chat-Kopfleiste, Profil-Sheet, Chat-Details, Nachrichtenkreise, Reaktionen) — vorher zeichnete die Chat-Kopfleiste nach einer anderen Regel als der Rest
- 🔠 Initiale skaliert mit dem Avatar (vorher winziger Buchstabe in großen Kreisen, z. B. Profil-Sheet und Chat-Details)
- ♿ Gruppen-Icon und der Platzhalter-Avatar unaufgelöster 1:1-Chats werden ebenfalls kontrastiert gezeichnet (vorher fixes Weiß bzw. Theme-Default — auf hellen Paletten-Farbtönen kaum lesbar)

## [1.11.0] - 2026-08-02

### Added
- 📤 **Multi-Send beim Teilen & Weiterleiten**: mehrere Chats auswählbar (Checkbox-Picker); geteilter Text/Link ist vor dem Senden bearbeitbar, Medien laufen durch das Caption-Sheet
- ↪️ **„Zum Chat"**-Button nach dem Weiterleiten (bei einem Ziel)
- 🖥️ **PiP-Vollbild**: Maximize/Restore-Button am schwebenden Videofenster (media_kit + YouTube)

### Fixed
- 🔒 App-Lock: Entsperr-Screen verrät die Mindestlänge nicht mehr (Hint nur noch im Setup); Mindestlänge zusätzlich im Controller erzwungen
- 🏷️ @-Mentions werden in Nachrichten-Bubbles zuverlässig hervorgehoben (auch zusammen mit Links — Vorschau-Karte bleibt)
- ✍️ Composer: Reply-/Edit-Banner wird nicht mehr von mehrzeiligen Entwürfen überdeckt (Fork p20); Anhang-Button bleibt beim Tippen sichtbar
- 🎨 Avatar-Farben endlich konsistent: EINE identitätsgebundene Farbe pro Nutzer auf allen Flächen (Chat-Liste, Header, Nachrichten-Kreise, Reaktionen, Teilen-Sheet, Vollbild) + einheitliche Initialen
- 🔢 Ungelesen-Badge flackert nicht mehr zwischen altem und neuem Stand beim App-Wechsel
- 🛡️ Verifizierung: kein Endlos-Spinner mehr (Timeout + Isolate), eigener Identitätsschlüssel wird beim Öffnen von Verifizierung/QR selbstheilend (re)veröffentlicht, „Jetzt veröffentlichen"-Button, klare Meldung bei ausstehender Chat-Anfrage
- 📎 Datei-/Videoversand überlebt das Verlassen des Chats (kein Abbruch/Fehler mehr)
- 📷 iOS-Fotos kommen in korrekter Ausrichtung an (EXIF-Orientation wird vor dem Metadaten-Strip in die Pixel gebacken); Bilder >16 MB werden ebenfalls von EXIF/GPS befreit
- 🎬 Inline-YouTube-Player zeichnet nicht mehr über die Chat-Kopfleiste
- 🌐 Landing-Logo rendert wieder in iOS Safari (defekte SVG-Filter entfernt)

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
