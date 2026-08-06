# Chattr — Flow-Charts (alle Abläufe)

Referenzdiagramme aller Kernabläufe. **Source of truth zusammen mit
`landing/assets/js/flow-sources.js`**, das die Diagramme auf der Landing-Page
rendert (Accordion in `index.html` Sektion `#technik` + ausgeklappt in
`technik.html`) — Änderungen hier bitte dort spiegeln (und umgekehrt,
Konvention in CLAUDE.md). Gerendert mit [Mermaid](https://mermaid.js.org/);
die Landing-Page bundelt `landing/assets/js/mermaid.min.js`.

## 👤 Konto & Profil

```mermaid
flowchart TD
    REG[Registrieren:<br/>nur ein Benutzername] --> ANON[Anonymes Konto —<br/>keine E-Mail, keine Telefonnummer]
    ANON --> KEY[Lokaler Verschlüsselungs-Schlüssel<br/>im Secure Storage des Geräts]
    KEY --> LDB[(Lokale Datenbank —<br/>komplett verschlüsselt)]
    ANON --> QR[Eigener QR-Code =<br/>einziger Weg, dich zu finden]
    AV[Avatar hochladen] --> AVS[Speicherung am Server,<br/>Broadcast an Kontakte]
    UN[Username ändern] --> AVS
    DEL[Konto löschen] --> WIPE[Server: alle Zeilen weg<br/>Gerät: Schlüssel + DB gelöscht]
    LOCK[App-Sperre optional:<br/>Face ID / Passcode + Blur im Hintergrund]
```

## 🔐 Konto-Wiederherstellung (Phrase & Backup)

Anonyme Konten haben sonst keine Wiederanmeldung — zwei Wege überleben einen Wipe.
**Backup-Datei:** ein passphrase-verschlüsseltes File (Session + Schlüssel), selbst
verwahrt. **Recovery-Phrase:** 24 Wörter, geräteunabhängig, ohne E-Mail — die App bleibt
anonym. Ablauf der Phrase (Challenge-Response, kein Passwort, Owner-Beweis per Signatur):

```mermaid
sequenceDiagram
    autonumber
    participant A as App (Gerät)
    participant F as Edge-Function
    participant S as Server (Auth/DB)
    Note over A,S: Aktivieren (eingeloggt)
    A->>A: 24-Wort-Phrase erzeugen<br/>→ Ed25519-Keypair ableiten
    A->>F: enroll-recovery (Public Key, mit Session)
    F->>S: synthetische E-Mail setzen +<br/>Public Key speichern
    A->>A: Phrase EINMALIG anzeigen<br/>(kopieren → Passwortmanager)
    Note over A,S: Wiederherstellen (frisches Gerät, keine Session)
    A->>A: Phrase eingeben → gleiches Keypair
    A->>F: recover-identity: Challenge anfordern
    F-->>A: Zufalls-Challenge (einmalig)
    A->>F: signierte Challenge (Ed25519)
    F->>F: Signatur prüfen (crypto.subtle)
    F->>S: admin.generateLink → token_hash
    F-->>A: token_hash
    A->>S: verifyOtp → volle Session,<br/>DIESELBE user_id (Chats intakt)
    A->>A: NEUER Identitäts-Schlüssel<br/>(Signal-Modell — alter ist unwiederbringlich)
    A->>S: Identitäts-Public-Key + pro Chat<br/>neuen (signierten) Public Key publishen
    Note over A,S: Kontakte sehen „Safety Number geändert“<br/>und verifizieren neu
```

## 🗨️ Chats: 1:1 & Gruppen

```mermaid
flowchart TD
    subgraph Einzelchat
        SCAN[QR des Kontakts scannen] --> DC[1:1-Chat entsteht sofort —<br/>beide tauschen Public Keys]
        DC --> NOADM[Kein Promote/Kick —<br/>stattdessen: Blockieren]
    end
    subgraph Gruppe
        CREATE[Gruppe erstellen] --> GQR[Gruppen-QR teilen]
        GQR --> PEND[Beitritt nur nach<br/>Admin-Freigabe]
        PEND --> ADM[Admins: Mitglieder verwalten,<br/>promoten, entfernen]
        ADM --> ROT[Schlüsselrotation bei<br/>Mitglieder-Änderung]
    end
    DC & PEND --> MUTE[Pro Chat: stummschalten bis X,<br/>Selbstzerstörungs-Timer, verlassen]
```

## 💬 Nachricht senden & empfangen

```mermaid
sequenceDiagram
    autonumber
    participant A as Alice (App)
    participant S as Server (Supabase)
    participant B as Bob (App)

    rect rgba(127,127,127,0.08)
    Note over A,B: Schlüsseltausch (bei Chat-Erstellung / QR-Join)
    A->>A: Hybrid-Schlüsselpaar (X25519 + ML-KEM-768)<br/>pro Chat erzeugen (Private Key nur lokal)
    A->>A: Chat-Key mit Identitäts-Schlüssel signieren<br/>(Ed25519, chat-gebunden)
    A->>S: Signierten Public Key veröffentlichen
    A->>S: Pool signierter Einmal-Prekeys veröffentlichen<br/>(Forward Secrecy — Public-Hälften, Private nur lokal)
    B->>B: Eigenes Schlüsselpaar erzeugen + signieren
    B->>S: Signierten Public Key + Einmal-Prekey-Pool veröffentlichen
    B->>B: Alices Key gegen gepinnte Identität prüfen —<br/>ein vom Server getauschter Key fällt auf ⚠️
    Note over A,B: Bei Member-Änderung: Schlüsselrotation<br/>(Rotation wird als Systemnachricht angekündigt)
    end

    rect rgba(127,127,127,0.08)
    Note over A,S: Senden
    A->>A: Nachricht mit Identitäts-Schlüssel signieren
    A->>S: Je Empfänger einen Einmal-Prekey beanspruchen<br/>(claim_prekey – kein Prekey → Fallback auf Static-Key)
    A->>A: Klartext pro Empfänger verschlüsseln<br/>(1 Kopie je Mitglied, inkl. Antwort-Vorschau)<br/>Schlüssel an Empfänger-Einmal-Prekey gewrappt (Forward Secrecy)<br/>Ciphertext an Chat+Absender+Nachricht gebunden (AAD)
    A->>S: N verschlüsselte Zeilen speichern
    S->>S: DB-Trigger
    par Realtime
        S-)B: Broadcast auf Kanal user:bob
    and Push
        S-)B: Push-Benachrichtigung<br/>(nur Absender, nie Inhalt)
    end
    end

    rect rgba(127,127,127,0.08)
    Note over S,B: Empfangen
    B->>B: Mit privatem Chat-Schlüssel entschlüsseln<br/>(Kontext-Bindung wird kryptografisch erzwungen)
    B->>B: Absender-Signatur prüfen —<br/>Fälschung wird als ⚠️ markiert (warn-only)
    B->>B: Klartext in lokale verschlüsselte Datenbank
    B->>S: Zustellbestätigung → Server-Ciphertext wird GELÖSCHT
    B->>B: Verbrauchten Einmal-Prekey (Private) LÖSCHEN<br/>→ dieselbe Nachricht ist nie wieder entschlüsselbar (Forward Secrecy)
    Note over S: Ab jetzt existiert die Nachricht<br/>nur noch auf Bobs Gerät
    B->>S: Beim Lesen: Lesebestätigung
    S-)A: Status-Häkchen (✓ / ✓✓)<br/>(Live-Broadcast — kann verloren gehen, s.u.)
    end

    rect rgba(127,127,127,0.08)
    Note over A,B: Offline-Aufholjagd (App-Start / Resume)
    B->>S: Verpasste Nachrichten abholen
    B->>B: Entschlüsseln + lokal speichern
    B->>S: Für neu geholte: Zustellbestätigung nachziehen
    A->>S: Status gesendeter Nachrichten abholen<br/>(get_sent_message_status, SECURITY DEFINER)
    S-)A: received_at / read_at je Empfänger → Häkchen nachziehen
    Note over A: Fängt Quittungen ab, die als Broadcast<br/>verloren gingen, während Alice zu war
    end
```

## 📎 Medien: Fotos, Videos, Dateien & Sprachnachrichten

```mermaid
sequenceDiagram
    autonumber
    participant A as Alice (App)
    participant ST as Storage (privater Bucket)
    participant S as Server (Supabase)
    participant B as Bob (App)

    A->>A: Frischen AES-256-GCM-Schlüssel<br/>für DIESE Datei erzeugen
    A->>A: Datei clientseitig verschlüsseln
    A->>ST: Nur den Ciphertext hochladen (bis 500 MB)
    A->>A: Dateischlüssel pro Empfänger<br/>hybrid verschlüsselt (KEM) in die Nachricht packen
    A->>S: Nachricht mit Datei-Descriptor senden<br/>(gleicher Fluss wie Textnachricht)
    S-)B: Realtime + Push
    B->>B: Dateischlüssel mit privatem Chat-Schlüssel entschlüsseln
    B->>ST: Ciphertext laden
    B->>B: Datei entschlüsseln, lokal cachen und anzeigen
    Note over A,ST: Fehlgeschlagener Upload:<br/>App löscht den Blob sofort selbst
    S->>ST: Täglicher Aufräum-Job löscht den Blob,<br/>sobald ALLE Empfänger gelesen haben und die<br/>Status-Zeilen bereinigt sind (24h-Schonfrist)
    Note over ST: Hard-Limit: spätestens 3 Monate<br/>nach Upload wird jeder Blob gelöscht
```

## 👥 Gruppen-Beitritt per QR-Code

```mermaid
sequenceDiagram
    autonumber
    participant N as Neues Mitglied
    participant S as Server (Supabase)
    participant AD as Admin

    N->>N: Gruppen-QR scannen
    N->>N: Eigenes Schlüsselpaar für den Chat erzeugen
    N->>S: Beitrittsanfrage (pending) + Public Key
    S-)AD: Realtime + Push: „Neue Beitrittsanfrage“
    AD->>S: Anfrage annehmen (oder ablehnen/blocken)
    S-)N: Realtime: „Du bist drin“
    S->>S: Systemnachricht an alle Mitglieder
    Note over N,AD: Ab jetzt verschlüsselt jeder Absender<br/>auch für den Public Key des neuen Mitglieds
```

**MCP-Agent-Variante (kein QR nötig):** Ein KI-Agent bindet einen von ihm
erstellten Chat per Token an einen Nutzer (`bind_mcp_chat`-RPC, Migration
`00038`). Dessen App entdeckt den Chat dann selbstständig (RLS-Sichtbarkeit
für `mcp_owner_id`) und durchläuft ab „Eigenes Schlüsselpaar erzeugen“ exakt
denselben Beitritts-Flow wie oben — nur dass „Neues Mitglied“ die eigene App
im Hintergrund ist statt ein QR-Scan. Die Beitrittsanfrage des **Owners** wird
dabei **serverseitig automatisch angenommen** (Trigger `auto_approve_mcp_owner`,
Migration `00039`): Da `mcp_owner_id` aus dem verifizierten Token stammt (nicht
spoofbar), promotet ein `SECURITY DEFINER`-Trigger die Pending-Zeile des Owners
sofort zu einer Mitgliedschaft — der Owner landet nie in der Approval-Queue und
ist unabhängig davon, ob gerade ein Agent läuft. Dabei wird der **Owner zum
alleinigen Admin** des Chats (der Agent wird degradiert, bleibt aber Mitglied
zum Senden) — sowohl beim Beitritt als auch per Backfill für bereits gebundene
Chats (`00044`). So sieht der Mensch die Beitrittsanfragen (Realtime + Push
gehen nur an Admins) und ein prompt-injizierter Agent kann den Chat nicht
verwalten. Beitrittsanfragen anderer Nutzer durchlaufen dadurch den normalen
Admin-Approve **beim Owner**. Details: `docs/MCP_AGENT_SERVER_PLAN.md`.

## ✉️ Gruppen-Einladung als Nachricht (Auto-Approve)

Seit 1.13 kann ein **Admin** eine Gruppe als **Einladungs-Nachricht** in einen
anderen Chat teilen — wer die Karte dort antippt, tritt **ohne weitere
Freigabe** bei. Der Inhalt der Karte (Gruppenname) reist Ende-zu-Ende
verschlüsselt; der Server speichert nur den prüfbaren Zustand des Tokens
(`chat_invites`, Migration `00069`).

```mermaid
sequenceDiagram
    autonumber
    participant AD as Admin
    participant S as Server (Supabase)
    participant E as Empfänger (im Zielchat)

    AD->>S: create_chat_invite(Gruppe, Zielchat) — nur Admins
    S-->>AD: Token (nur im Zielchat einlösbar)
    AD->>S: Einladungskarte als E2E-Nachricht in den Zielchat
    S-)E: Realtime + Push (normale Nachricht)
    E->>E: Eigenes Schlüsselpaar für die Gruppe erzeugen
    E->>S: redeem_chat_invite(Token) + Public Key
    S->>S: Prüft: nicht widerrufen · Mitglied im Zielchat · nicht gesperrt
    S-)E: Mitgliedschaft sofort (kein Admin-Approve)
    Note over AD,S: Admin kann die Einladung jederzeit widerrufen —<br/>die Karte funktioniert dann nicht mehr
```

**Warum das sicher bleibt:** Der Token allein öffnet keine Tür. Einlösen kann
nur, wer **Mitglied des Chats ist, in den die Einladung geschickt wurde** —
eine weitergeleitete Einladung ist wertlos. Gruppen-Sperren gelten weiter,
und Erstellen wie Widerrufen können nur Admins (alles serverseitig erzwungen,
`SECURITY DEFINER` + Negativtests).

## 🤖 Chat-Zusammenfassung durch den Agenten (nur MCP-Chats)

Der Zusammenfassen-Knopf existiert **nur in MCP-Chats** — in normalen Chats
hat die Gegenseite nie zugestimmt, dass ein Modell mitliest. Anfrage und
Antwort reisen als **gewöhnliche E2E-verschlüsselte Nachrichten** mit
maschinenlesbarem Rumpf (der Agent ist kein Server, den die App aufrufen
könnte — er wird von einer Nachricht geweckt). Der Server sieht nur
Ciphertext; ein serverseitiges Zusammenfassen schied genau deshalb aus.

```mermaid
sequenceDiagram
    autonumber
    participant U as Nutzer (App)
    participant S as Server (Supabase)
    participant AG as Hauptagent

    U->>S: Anfrage als E2E-Nachricht (message_type=summary)
    Note over S: Kein Push (Gate 00068) — Realtime feuert normal
    S-)AG: Realtime weckt den Agenten
    AG->>AG: Entschlüsseln, Verlauf zusammenfassen
    AG->>S: Antwort als E2E-Nachricht (summary, for=Anfrage-Id)
    S-)U: Realtime: Antwort
    U->>U: Sheet zeigt die Zusammenfassung — flüchtig,<br/>keine Blase, kein Ungelesen-Zähler
    Note over U,AG: Läuft gerade keine Agenten-Sitzung,<br/>sagt das Sheet nach ~60 s ehrlich „keine Antwort“
```

## 🛡️ Identität & Verifizierung (Safety Numbers)

Der Trust-Layer aus dem Security-Audit 2026-07 (C1/H1/M3/H2): ein langlebiger
**Identitäts-Schlüssel** pro Konto beglaubigt alle Chat-Schlüssel und
Nachrichten, damit auch ein **böswilliger Server** keine Schlüssel tauschen
oder Nachrichten fälschen kann, ohne dass die App warnt (warn-only — Senden
bleibt immer möglich).

```mermaid
flowchart TD
    IK[Identitäts-Schlüssel Ed25519 —<br/>einmal pro Konto, Private Key nur lokal] --> PUB[Public Key steht im Profil]
    IK --> SIGK[signiert jeden Chat-Schlüssel<br/>chat-gebunden]
    IK --> SIGM[signiert jede Nachricht<br/>Kontext: Chat + Absender + ID]
    QR2[Persönlicher QR-Code trägt<br/>den Identitäts-Schlüssel] --> PIN[Beim Scannen gepinnt =<br/>✅ verifiziert]
    PUB --> TOFU[Ohne Scan: Trust-on-first-use —<br/>Badge „unverifiziert“]
    PIN & TOFU --> SN[Safety Number — 60 Ziffern,<br/>beide Seiten sehen dieselbe]
    SN --> CMP[Persönlich/telefonisch vergleichen →<br/>„als verifiziert markieren“]
    PIN --> CH{Identitäts-Schlüssel<br/>ändert sich?}
    CH -->|Neuinstallation, Recovery —<br/>oder Angriff| WARN[⚠️ Banner „Safety Number geändert“ —<br/>neu vergleichen, dann akzeptieren]
    SIGK --> MITM[Server tauscht einen Chat-Key? →<br/>Signatur passt nicht → ⚠️ Warnung]
    SIGM --> FORGE[Server injiziert eine Nachricht? →<br/>Bubble wird als „nicht verifiziert“ markiert]
```

## 🔔 Push-Benachrichtigungen

```mermaid
flowchart LR
    MSG[Neue Nachricht<br/>in der DB] --> TRG[Postgres-Trigger]
    REAC[Neue Reaktion 👍] --> TRG
    TRG -->|nicht stummgeschaltet| EF[Edge Function<br/>send-push-notification]
    EF -->|Gerät rendert selbst<br/>NUR IDs, keine Namen| FCM
    EF -->|Gerät rendert nicht selbst<br/>Chatname + Absendername| FCM[Firebase Cloud Messaging]
    FCM --> AND[Android-Gerät<br/>baut den Text selbst<br/>aus lokalem Namens-Cache]
    FCM --> IOS[iPhone/iPad via APNs<br/>noch Klartext — braucht<br/>Notification Service Extension]
    FCM --> WEB[Browser/PWA<br/>Service Worker<br/>noch Klartext — ungetestet]
    AND & IOS & WEB --> TAP[Tippen öffnet<br/>direkt den Chat]
    TRG -.->|App gerade offen| INAPP[Kein System-Banner —<br/>In-App-Banner + Ton]
```

## ⚡ Antworten, Reaktionen, Bearbeiten, Löschen & Selbstzerstörung

```mermaid
flowchart TD
    subgraph Aktionen
        RP[↩️ Antworten] --> RPT[Zitat-Vorschau wird pro Empfänger<br/>verschlüsselt mitgeschickt]
        R[👍 Reaktion] --> RT[Trigger broadcastet<br/>an alle Mitglieder]
        E[✏️ Bearbeiten] --> ET[Absender verschlüsselt neu<br/>pro Empfänger, mit Bearbeitet-Marker]
        D[🗑️ Für alle löschen] --> DT[Zeilen weg — Broadcast<br/>löscht auch lokale Kopien]
        T[⏳ Selbstzerstörung an/aus] --> TT[expires_at serverseitig —<br/>läuft ab, auch wenn die App zu ist]
        T --> TS[DB-Trigger: verschlüsselte Systemnachricht<br/>an alle — wer, an/aus, welche Dauer]
    end
    RPT & RT & ET & DT & TS --> BUS[Ein Realtime-Kanal<br/>user:&lt;userId&gt;]
    BUS --> UI[Alle Geräte aktualisieren<br/>sich live]
```

## 🚫 Blockieren (1:1-Chats)

```mermaid
flowchart TD
    BLK[Alice blockiert Bob] --> TBL[(blocked_users —<br/>nur Alice sieht ihre Liste)]
    BLK --> LV[Alice verlässt den 1:1-Chat]
    TBL --> G1{DB-Trigger}
    G1 -->|Bob scannt Alices QR erneut| REJ1[❌ Chat-Erstellung<br/>wird abgelehnt]
    G1 -->|Bob schreibt im alten 1:1| REJ2[❌ Nachricht<br/>wird abgelehnt]
    UNB[Alice entblockt<br/>in den Einstellungen] --> OK[✅ Kontakt wieder möglich]
    Note[Durchgesetzt in der Datenbank —<br/>keine App kann es umgehen]
```

## Kernprinzipien

- **Der Server sieht nie Klartext.** Jede Nachricht wird clientseitig pro
  Empfänger verschlüsselt (eine DB-Zeile je Empfänger); Medien werden vor dem
  Upload AES-GCM-verschlüsselt.
- **Der Server vergisst.** Nach der Zustellung (`markAsReceived`) wird der
  Ciphertext serverseitig gelöscht — die lokale, verschlüsselte Kopie ist
  dann die einzige. Erhalten bleibt nur die inhaltslose **Status-Zeile**
  (Zeitstempel `received_at` / `read_at` je Empfänger); daraus zieht der
  Absender verpasste Häkchen bei App-Start/Resume nach (Backfill).
- **Ein Realtime-Kanal pro User.** Alle Events (Nachrichten, Reactions,
  Edits, Membership) laufen über einen einzigen Broadcast-Kanal
  `user:<userId>` (Event-Bus), nicht über viele Tabellen-Subscriptions.
  Ein verpasster Broadcast (Client war zu) wird bei Start/Resume nachgeholt —
  Nachrichten wie Status-Häkchen.
- **Selbstzerstörung & Blocks** setzen serverseitig an (TTL-Spalte
  `expires_at`, `blocked_users`-Trigger) — Clients können sie nicht umgehen.
- **Auch Medien-Blobs werden gelöscht** (Storage): fehlgeschlagene Uploads
  sofort durch die App; sonst täglicher Reaper, sobald alle Empfänger gelesen
  haben und die Status-Zeilen bereinigt sind (24h-Schonfrist); Hard-Limit
  3 Monate nach Upload (`cleanup-old-media`, Migrationen 00018/00034).
- **Schlüssel sind beglaubigt** (Audit C1): ein Ed25519-Identitäts-Schlüssel
  pro Konto signiert jeden per-Chat-Schlüssel (chat-gebunden). TOFU-Pinning +
  QR-Verifikation + Safety Numbers (Signal-Stil); ein getauschter Schlüssel
  löst eine Warnung aus. Warn-only — nichts blockiert das Senden.
- **Nachrichten sind signiert & kontextgebunden** (Audit H1/M3/H2): Envelope
  v4 trägt eine Identitäts-Signatur über `chat_id‖sender_id‖message_id‖
  plaintext`, die AES-GCM-Schicht bindet denselben Kontext als AAD
  (kein Splice/Relabel/Replay), und der KEM-Key ist hybrid-only mit
  Scheme-Byte (kein stiller X25519-Downgrade).
- **Forward Secrecy** (Audit P3, Envelope v5): jeder Empfänger veröffentlicht
  einen Pool signierter **Einmal-Prekeys**; der Absender wrappt den
  Nachrichtenschlüssel an einen davon, der Empfänger entschlüsselt einmal und
  **löscht** die private Prekey-Hälfte. Danach ist ein mitgeschnittener
  Ciphertext selbst bei späterer Geräte-Kompromittierung nicht mehr zu öffnen.
  Kein Prekey verfügbar → Fallback auf v4 (kein Nachrichtenverlust).
- **Server-Härtung** (Audit M1/H4/H3): `profiles`-SELECT ist auf den eigenen
  Kontext gescoped (keine Nutzer-Enumeration), privilegierte
  SECURITY-DEFINER-Funktionen haben kein öffentliches EXECUTE mehr, und der
  Link-Preview-Proxy validiert Ziele DNS-Resolve-fest gegen SSRF.
