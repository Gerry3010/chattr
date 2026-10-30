// Flowchart sources for the technology section (index.html, accordion) and the
// full view (technik.html). Mirrored from docs/FLOW.md — when the flows change,
// update BOTH (the convention is in CLAUDE.md).
window.CHATTR_FLOWS = [
    {
        id: 'konto',
        title: 'Konto & Profil',
        icon: '<svg viewBox="0 0 24 24" width="26" height="26"><circle cx="12" cy="12" r="11" fill="#14b8a6"/><circle cx="12" cy="9.5" r="3.4" fill="#fff"/><path d="M5.5 19a6.5 5.4 0 0 1 13 0z" fill="#fff"/></svg>',
        source: `flowchart TD
    REG[Registrieren:<br/>nur ein Benutzername] --> ANON[Anonymes Konto:<br/>keine E-Mail, keine Telefonnummer]
    ANON --> KEY[Lokaler Verschlüsselungs-Schlüssel<br/>im Secure Storage des Geräts]
    KEY --> LDB[("Lokale Datenbank: Inhalte verschlüsselt,<br/>Datei selbst noch nicht (SQLCipher geplant).<br/>Zeitstempel und Reaktionen liegen offen")]
    ANON --> QR[Eigener QR-Code oder Kennung.<br/>Schreiben darf trotzdem nur,<br/>wer eine Anfrage stellt und Antwort bekommt]
    AV[Avatar hochladen] --> AVS[Speicherung am Server,<br/>Broadcast an Kontakte]
    UN[Username ändern] --> AVS
    DEL[Konto löschen] --> WIPE[Server: alle Zeilen weg<br/>Gerät: Schlüssel + DB gelöscht]
    LOCK[App-Sperre optional:<br/>Face ID / Passcode + Blur im Hintergrund]`,
    },
    {
        id: 'wiederherstellung',
        title: 'Konto-Wiederherstellung (Phrase & Backup)',
        icon: '<svg viewBox="0 0 24 24" width="26" height="26"><circle cx="12" cy="12" r="11" fill="#f59e0b"/><path d="M10 7a3 3 0 0 1 3 3v1h1a1 1 0 0 1 1 1v4a1 1 0 0 1-1 1H8a1 1 0 0 1-1-1v-4a1 1 0 0 1 1-1h1v-1a1 1 0 0 0-2 0" fill="none" stroke="#fff" stroke-width="1.4"/></svg>',
        source: `sequenceDiagram
    autonumber
    participant A as App (Gerät)
    participant F as Edge-Function
    participant S as Server (Auth/DB)
    Note over A,S: Aktivieren (eingeloggt)
    A->>A: 24-Wort-Phrase erzeugen<br/>→ Ed25519-Keypair ableiten
    A->>F: enroll-recovery (Public Key, mit Session)
    F->>S: synthetische E-Mail setzen +<br/>Public Key speichern
    A->>A: Phrase nur einmal anzeigen<br/>(kopieren → Passwortmanager)
    Note over A,S: Wiederherstellen (frisches Gerät, keine Session)
    A->>A: Phrase eingeben → gleiches Keypair
    A->>F: recover-identity: Challenge anfordern
    F-->>A: Zufalls-Challenge (einmalig)
    A->>F: signierte Challenge (Ed25519)
    F->>F: Signatur prüfen (crypto.subtle)
    F->>S: alle bisherigen Sitzungen beenden<br/>(das alte Gerät wird abgemeldet)
    F->>S: admin.generateLink → token_hash
    F-->>A: token_hash
    A->>S: verifyOtp → volle Session,<br/>dieselbe user_id (Chats intakt)
    A->>A: Neuer Identitäts-Schlüssel<br/>(Signal-Modell: alter ist<br/>unwiederbringlich)
    A->>S: Identitäts-Public-Key + pro Chat<br/>neuen (signierten) Public Key publishen
    Note over A,S: Kontakte sehen „Sicherheitsnummer geändert“<br/>und verifizieren neu`,
    },
    {
        id: 'chats',
        title: 'Chats: 1:1 & Gruppen',
        icon: '<svg viewBox="0 0 24 24" width="26" height="26"><circle cx="12" cy="12" r="11" fill="#6366f1"/><path d="M5.5 7.5h9a1.5 1.5 0 0 1 1.5 1.5v4a1.5 1.5 0 0 1-1.5 1.5H9l-2.8 2.2V14.5H5.5A1.5 1.5 0 0 1 4 13V9a1.5 1.5 0 0 1 1.5-1.5z" fill="#fff"/><path d="M17.5 10h1A1.5 1.5 0 0 1 20 11.5v3a1.5 1.5 0 0 1-1.5 1.5H18v1.8L15.8 16h-1.3" fill="none" stroke="#fff" stroke-width="1.3"/></svg>',
        source: `flowchart TD
    subgraph Einzelchat
        SCAN[QR scannen oder Kennung eingeben] --> REQ[Chat-Anfrage, auch nach dem Scan]
        REQ --> DEC{Angenommen?}
        DEC -->|ja| DC[1:1-Chat entsteht,<br/>beide tauschen Public Keys]
        DEC -->|nein| SIL[Still abgelehnt: Der Anfragende erfährt es<br/>nicht, ein zweiter Versuch ändert nichts]
        DC --> NOADM[Kein Promote/Kick,<br/>stattdessen Blockieren]
    end
    subgraph Gruppe
        CREATE[Gruppe erstellen] --> GQR[Gruppen-QR teilen]
        GQR --> PEND[Beitritt nur nach<br/>Admin-Freigabe]
        PEND --> ADM[Admins: Mitglieder verwalten,<br/>promoten, entfernen]
        ADM --> ROT[Schlüsselrotation bei<br/>Mitglieder-Änderung]
    end
    DC & PEND --> MUTE[Pro Chat: stummschalten bis X,<br/>Selbstzerstörungs-Timer, verlassen]`,
    },
    {
        id: 'nachricht',
        title: 'Nachricht senden & empfangen',
        icon: '<svg viewBox="0 0 24 24" width="26" height="26"><circle cx="12" cy="12" r="11" fill="#3b82f6"/><path d="M5 12l13-6-4.5 12-2.7-4.2L5 12z" fill="#fff"/><path d="M10.8 13.8L18 6" stroke="#3b82f6" stroke-width="0.9"/></svg>',
        source: `sequenceDiagram
    autonumber
    participant A as Alice (App)
    participant S as Server (Supabase)
    participant B as Bob (App)

    rect rgba(127,127,127,0.08)
    Note over A,B: Schlüsseltausch (bei Chat-Erstellung / QR-Join)
    A->>A: Hybrid-Schlüsselpaar (X25519 + ML-KEM-768)<br/>pro Chat erzeugen (Private Key nur lokal)
    A->>A: Chat-Key mit Identitäts-Schlüssel signieren<br/>(Ed25519, chat-gebunden)
    A->>S: Signierten Public Key veröffentlichen
    A->>S: Pool signierter Einmal-Prekeys veröffentlichen<br/>(Forward Secrecy: Public-Hälften, Private nur lokal)
    B->>B: Eigenes Schlüsselpaar<br/>erzeugen + signieren
    B->>S: Signierten Public Key + Einmal-Prekey-Pool veröffentlichen
    B->>B: Alices Key gegen gepinnte<br/>Identität prüfen: Ein vom<br/>Server getauschter Key<br/>fällt auf ⚠️
    Note over A,B: Bei Member-Änderung: Schlüsselrotation<br/>(Rotation wird als Systemnachricht angekündigt)
    end

    rect rgba(127,127,127,0.08)
    Note over A,S: Senden
    A->>A: Nachricht mit Identitäts-<br/>Schlüssel signieren
    A->>S: Je Empfänger einen Einmal-Prekey beanspruchen<br/>(claim_prekey, ohne Prekey → Fallback auf Static-Key)
    A->>A: Klartext pro Empfänger<br/>verschlüsseln (1 Kopie je<br/>Mitglied, inkl.<br/>Antwort-Vorschau)<br/>Schlüssel an Empfänger-<br/>Einmal-Prekey gewrappt<br/>(Forward Secrecy)<br/>Ciphertext an Chat+Absender+<br/>Nachricht gebunden (AAD)
    A->>S: N verschlüsselte Zeilen speichern
    S->>S: DB-Trigger
    par Realtime
        S-)B: Broadcast auf privatem Kanal p:user:bob
    and Push
        S-)B: Push-Benachrichtigung<br/>(nur Kennungen, nie Inhalt oder Name)
    end
    end

    rect rgba(127,127,127,0.08)
    Note over S,B: Empfangen
    B->>B: Mit privatem Chat-Schlüssel entschlüsseln<br/>(Kontext-Bindung wird kryptografisch erzwungen)
    B->>B: Absender-Signatur prüfen:<br/>Fälschung wird als ⚠️ markiert (nur Warnung)
    B->>B: Klartext in die lokale Datenbank:<br/>Inhalte verschlüsselt, die Datei selbst noch nicht
    B->>S: Zustellbestätigung → Server löscht den Ciphertext
    B->>B: Verbrauchten Einmal-Prekey (Private) löschen<br/>→ dieselbe Nachricht ist nie wieder<br/>entschlüsselbar (Forward Secrecy)
    Note over S,B: Ab jetzt liegt die Nachricht<br/>nicht mehr auf dem Server
    B->>S: Beim Lesen: Lesebestätigung
    S-)A: Status-Häkchen (✓ / ✓✓)<br/>(Live-Broadcast, kann verloren gehen, s. u.)
    end

    rect rgba(127,127,127,0.08)
    Note over A,B: Offline-Aufholjagd (App-Start / Resume)
    B->>S: Verpasste Nachrichten abholen
    B->>B: Entschlüsseln +<br/>lokal speichern
    B->>S: Für neu geholte: Zustellbestätigung nachziehen
    A->>S: Status gesendeter Nachrichten abholen<br/>(get_sent_message_status, SECURITY DEFINER)
    S-)A: received_at / read_at je Empfänger → Häkchen nachziehen
    Note over A,S: Fängt Quittungen ab, die als Broadcast<br/>verloren gingen, während Alice zu war
    end`,
    },
    {
        id: 'medien',
        title: 'Medien: Fotos, Videos, Dateien & Sprachnachrichten',
        icon: '<svg viewBox="0 0 24 24" width="26" height="26"><circle cx="12" cy="12" r="11" fill="#a855f7"/><rect x="5.5" y="7" width="13" height="10" rx="1.6" fill="#fff"/><circle cx="9.2" cy="10.4" r="1.3" fill="#a855f7"/><path d="M7 15.5l3.2-3 2.3 2.1 2.6-2.6 2.4 3.5z" fill="#a855f7"/></svg>',
        source: `sequenceDiagram
    autonumber
    participant A as Alice (App)
    participant ST as Storage (privater Bucket)
    participant S as Server (Supabase)
    participant B as Bob (App)

    A->>A: Frischen AES-256-GCM-Schlüssel<br/>für diese eine Datei erzeugen
    A->>A: Datei clientseitig verschlüsseln
    A->>ST: Nur den Ciphertext hochladen (bis 500 MB)
    A->>A: Dateischlüssel pro Empfänger<br/>hybrid verschlüsselt (KEM)<br/>in die Nachricht packen
    A->>S: Nachricht mit Datei-Descriptor senden<br/>(gleicher Fluss wie Textnachricht)
    S-)B: Realtime + Push
    B->>B: Dateischlüssel mit privatem<br/>Chat-Schlüssel entschlüsseln
    B->>ST: Ciphertext laden
    B->>B: Datei entschlüsseln und anzeigen
    Note over S,B: Große Videos (in 6-MB-Blöcken<br/>hochgeladen) spielen, während<br/>sie laden: Jeder Block trägt<br/>seine eigene Prüfsumme, ist also<br/>einzeln verifizierbar, und was<br/>verifiziert ist, darf laufen.<br/>Dabei entsteht keine entschlüsselte<br/>Datei auf der Platte.
    Note over S,B: Eine kleine Datei ist ein Geheimtext<br/>mit nur einer Prüfsumme am Ende:<br/>Sie wird erst ganz geprüft, dann<br/>angezeigt. Alles andere hieße,<br/>Ungeprüftes zu zeigen.
    Note over A,ST: Fehlgeschlagener Upload:<br/>App löscht den Blob sofort selbst
    S->>ST: Täglicher Aufräum-Job löscht den Blob,<br/>sobald alle Empfänger gelesen haben und die<br/>Status-Zeilen bereinigt sind (24h-Schonfrist)
    Note over ST,S: Hard-Limit: spätestens 3 Monate<br/>nach Upload wird jeder Blob gelöscht`,
    },
    {
        id: 'shots',
        title: 'Shots: einmal ansehen',
        icon: '<svg viewBox="0 0 24 24" width="26" height="26"><circle cx="12" cy="12" r="11" fill="#e0245e"/><circle cx="12" cy="12" r="6" fill="none" stroke="#fff" stroke-width="1.6"/><path d="M12 8.4v3.9l2.6 1.6" fill="none" stroke="#fff" stroke-width="1.6" stroke-linecap="round"/></svg>',
        source: `sequenceDiagram
    autonumber
    participant A as Alice (App)
    participant ST as Storage (privater Bucket)
    participant S as Server (Supabase)
    participant B as Bob (App)

    A->>A: Foto/Video als Shot markieren
    A->>ST: Wie jede Datei: nur Ciphertext hochladen
    A->>S: Nachricht als Umschlag v6 senden<br/>(Anhang steckt innen, kein Medien-Marker)
    Note over A,S: v6 ist eine Bedingung an den Leser.<br/>Wer sie nicht kennt, sieht die Karte<br/>„neuere App-Version nötig“, nie das Bild
    S-)B: Realtime + Push (Vorschau: nur „Shot“)
    B->>B: Blase „Shot“, noch nichts geladen
    B->>B: Antippen, Rückfrage bestätigen
    B->>ST: Ciphertext laden, entschlüsseln, einmal anzeigen
    B->>S: Erst jetzt als gelesen markieren
    B->>B: Schon beim Öffnen: Anhang und<br/>Schlüssel aus der lokalen Kopie löschen
    Note over B,ST: Das ist der Brand: Ein Empfänger darf<br/>den Blob gar nicht löschen, ohne Schlüssel<br/>öffnet ihn aber niemand mehr
    S->>ST: Aufräum-Job entfernt den Blob,<br/>sobald alle ihn abgeholt haben
    Note over A,B: 24 h nach dem Öffnen verschwindet<br/>auch die Blase, auf beiden Seiten`,
    },
    {
        id: 'gruppen',
        title: 'Gruppen-Beitritt per QR-Code',
        icon: '<svg viewBox="0 0 24 24" width="26" height="26"><circle cx="12" cy="12" r="11" fill="#f97316"/><circle cx="9" cy="10" r="2.4" fill="#fff"/><circle cx="15.5" cy="10.5" r="1.9" fill="#ffe1c9"/><path d="M4.6 16.6a4.6 3.6 0 0 1 8.8 0z" fill="#fff"/><path d="M13.9 16.6a3.8 3 0 0 1 5.8-2.4" fill="none" stroke="#ffe1c9" stroke-width="1.4"/></svg>',
        source: `sequenceDiagram
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
    Note over N,AD: Ab jetzt verschlüsselt jeder Absender<br/>auch für den Public Key des neuen Mitglieds`,
    },
    {
        id: 'einladung',
        title: 'Gruppen-Einladung als Nachricht (Auto-Approve)',
        icon: '<svg viewBox="0 0 24 24" width="26" height="26"><circle cx="12" cy="12" r="11" fill="#0ea5e9"/><path d="M5.5 8.2h13v8.2h-13z" fill="#fff"/><path d="M5.5 8.2l6.5 4.6 6.5-4.6" fill="none" stroke="#0ea5e9" stroke-width="1.4"/><circle cx="17.4" cy="7.4" r="3" fill="#22c55e"/><path d="M16 7.4l1 1 1.8-1.9" fill="none" stroke="#fff" stroke-width="1.3" stroke-linecap="round"/></svg>',
        source: `sequenceDiagram
    autonumber
    participant AD as Admin
    participant S as Server (Supabase)
    participant E as Empfänger (im Zielchat)

    AD->>S: Einladung erstellen (nur Admins)
    S-->>AD: Token (nur im Zielchat einlösbar)
    AD->>S: Einladungskarte als E2E-Nachricht in den Zielchat
    S-)E: Realtime + Push (normale Nachricht)
    E->>E: Eigenes Schlüsselpaar für die Gruppe erzeugen
    E->>S: Einlösen (Token + Public Key)
    S->>S: Prüft: nicht widerrufen · Mitglied im Zielchat · nicht gesperrt
    S-)E: Mitgliedschaft sofort, ohne Admin-Freigabe
    Note over AD,S: Admin kann die Einladung jederzeit widerrufen,<br/>die Karte funktioniert dann nicht mehr`,
    },
    {
        id: 'zusammenfassung',
        title: 'Chat-Zusammenfassung durch den Agenten (nur MCP-Chats)',
        icon: '<svg viewBox="0 0 24 24" width="26" height="26"><circle cx="12" cy="12" r="11" fill="#8b5cf6"/><path d="M12 5l1.2 3 3 1.2-3 1.2-1.2 3-1.2-3-3-1.2 3-1.2z" fill="#fff"/><path d="M16.8 13.4l.7 1.7 1.7.7-1.7.7-.7 1.7-.7-1.7-1.7-.7 1.7-.7z" fill="#e9d5ff"/></svg>',
        source: `sequenceDiagram
    autonumber
    participant U as Nutzer (App)
    participant S as Server (Supabase)
    participant AG as Hauptagent

    U->>S: Anfrage als E2E-Nachricht (Typ summary)
    Note over S,AG: Kein Push, Realtime feuert normal
    S-)AG: Realtime weckt den Agenten
    AG->>AG: Entschlüsseln, Verlauf zusammenfassen
    AG->>S: Antwort als E2E-Nachricht (für die Anfrage-Id)
    S-)U: Realtime: Antwort
    U->>U: Sheet zeigt die Zusammenfassung flüchtig:<br/>keine Blase, kein Ungelesen-Zähler
    Note over U,AG: Läuft keine Agenten-Sitzung,<br/>sagt das Sheet nach ~60 s „keine Antwort“`,
    },
    {
        id: 'identitaet',
        title: 'Identität & Verifizierung (Sicherheitsnummern)',
        icon: '<svg viewBox="0 0 24 24" width="26" height="26"><circle cx="12" cy="12" r="11" fill="#10b981"/><path d="M12 4.8l5.5 2.2v4.2c0 3.6-2.3 6.4-5.5 7.8-3.2-1.4-5.5-4.2-5.5-7.8V7z" fill="#fff"/><path d="M9.4 12l1.8 1.8 3.4-3.6" fill="none" stroke="#10b981" stroke-width="1.8" stroke-linecap="round"/></svg>',
        source: `flowchart TD
    IK[Identitäts-Schlüssel Ed25519:<br/>einmal pro Konto, Private Key nur lokal] --> PUB[Public Key steht im Profil]
    IK --> SIGK[signiert jeden Chat-Schlüssel<br/>chat-gebunden]
    IK --> SIGM[signiert jede Nachricht<br/>Kontext: Chat + Absender + ID]
    QR2[Persönlicher QR-Code trägt<br/>den Identitäts-Schlüssel] --> PIN[Beim Scannen gepinnt =<br/>✅ verifiziert]
    PUB --> TOFU[Ohne Scan: Trust-on-first-use,<br/>Badge „unverifiziert“]
    PIN & TOFU --> SN[Sicherheitsnummer: 60 Ziffern,<br/>beide Seiten sehen dieselbe]
    SN --> CMP[Persönlich/telefonisch vergleichen →<br/>„als verifiziert markieren“]
    PIN --> CH{Identitäts-Schlüssel<br/>ändert sich?}
    CH -->|Neuinstallation, Recovery<br/>oder Angriff| WARN[⚠️ Banner „Sicherheitsnummer geändert“:<br/>neu vergleichen, dann akzeptieren]
    SIGK --> MITM[Server tauscht einen Chat-Key? →<br/>Signatur passt nicht → ⚠️ Warnung]
    SIGM --> FORGE[Server injiziert eine Nachricht? →<br/>Bubble wird als „nicht verifiziert“ markiert]`,
    },
    {
        id: 'push',
        title: 'Push-Benachrichtigungen',
        icon: '<svg viewBox="0 0 24 24" width="26" height="26"><circle cx="12" cy="12" r="11" fill="#ef4444"/><path d="M12 5.2a4.4 4.4 0 0 1 4.4 4.4c0 3 .9 4.2 1.6 4.9H6c.7-.7 1.6-1.9 1.6-4.9A4.4 4.4 0 0 1 12 5.2z" fill="#fff"/><path d="M10.3 16.4a1.8 1.8 0 0 0 3.4 0z" fill="#fff"/></svg>',
        source: `flowchart LR
    MSG[Neue Nachricht<br/>in der DB] --> TRG[Postgres-Trigger]
    REAC[Neue Reaktion 👍] --> TRG
    TRG -->|nicht stummgeschaltet| EF[Edge Function<br/>send-push-notification]
    EF -->|Gerät rendert selbst<br/>nur IDs, keine Namen| FCM
    EF -->|Gerät rendert nicht selbst<br/>Chatname + Absendername| FCM[Firebase Cloud Messaging]
    FCM --> AND[Android-Gerät<br/>baut den Text selbst<br/>aus lokalem Namens-Cache]
    FCM --> IOS[iPhone/iPad via APNs<br/>Benachrichtigungs-Erweiterung<br/>baut den Text selbst]
    FCM --> WEB[Browser/PWA<br/>Service Worker<br/>noch Klartext, ungetestet]
    AND & IOS & WEB --> TAP[Tippen öffnet<br/>direkt den Chat]
    TRG -.->|App gerade offen| INAPP[Kein System-Banner,<br/>In-App-Banner + Ton]`,
    },
    {
        id: 'aktionen',
        title: 'Antworten, Reaktionen, Bearbeiten, Löschen & Selbstzerstörung',
        icon: '<svg viewBox="0 0 24 24" width="26" height="26"><circle cx="12" cy="12" r="11" fill="#eab308"/><path d="M13.2 4.5L7 13h3.6l-.9 6.5L16 11h-3.7z" fill="#fff"/></svg>',
        source: `flowchart TD
    subgraph Aktionen
        RP[↩️ Antworten] --> RPT[Zitat-Vorschau wird pro Empfänger<br/>verschlüsselt mitgeschickt]
        R[👍 Reaktion] --> RT[Emoji liegt beim Server im Klartext,<br/>als einzige Aktion. Trigger broadcastet<br/>an alle Mitglieder]
        E[✏️ Bearbeiten] --> ET[Absender verschlüsselt neu<br/>pro Empfänger, mit Bearbeitet-Marker]
        D[🗑️ Für alle löschen] --> DT[Zeilen weg, Broadcast<br/>löscht auch lokale Kopien]
        T[⏳ Selbstzerstörung an/aus] --> TT[expires_at serverseitig:<br/>läuft ab, auch wenn die App zu ist]
        T --> TS[DB-Trigger: verschlüsselte Systemnachricht<br/>an alle: wer, an/aus, welche Dauer]
    end
    RPT & RT & ET & DT & TS --> BUS[Ein privater Realtime-Kanal<br/>p:user:&lt;userId&gt;]
    BUS --> UI[Alle Geräte aktualisieren<br/>sich live]`,
    },
    {
        id: 'blockieren',
        title: 'Blockieren (1:1-Chats)',
        icon: '<svg viewBox="0 0 24 24" width="26" height="26"><circle cx="12" cy="12" r="11" fill="#dc2626"/><circle cx="12" cy="12" r="6.2" fill="none" stroke="#fff" stroke-width="2"/><path d="M7.8 7.8l8.4 8.4" stroke="#fff" stroke-width="2"/></svg>',
        source: `flowchart TD
    BLK[Alice blockiert Bob] --> TBL[(blocked_users:<br/>nur Alice sieht ihre Liste)]
    BLK --> LV[Alice verlässt den 1:1-Chat]
    TBL --> G1{DB-Trigger}
    G1 -->|Bob scannt Alices QR erneut| REJ1[❌ Chat-Erstellung<br/>wird abgelehnt]
    G1 -->|Bob schreibt im alten 1:1| REJ2[❌ Nachricht<br/>wird abgelehnt]
    UNB[Alice entblockt<br/>in den Einstellungen] --> OK[✅ Kontakt wieder möglich]
    Note[Durchgesetzt in der Datenbank:<br/>keine App kann es umgehen]`,
    },
    {
        id: 'anrufe',
        title: 'Anrufe (1:1, Ton)',
        icon: '<svg viewBox="0 0 24 24" width="26" height="26"><circle cx="12" cy="12" r="11" fill="#16a34a"/><path d="M8.3 6h2l1.1 3-1.5 1a7.8 7.8 0 0 0 4.9 4.9l1-1.5 3 1.1v2a1.5 1.5 0 0 1-1.6 1.5A11.6 11.6 0 0 1 6.8 7.6 1.5 1.5 0 0 1 8.3 6z" fill="#fff"/></svg>',
        source: `sequenceDiagram
    autonumber
    participant A as Alice (App)
    participant S as Server (Supabase)
    participant T as Vermittlungsdienst
    participant P as Push (Apple/Google)
    participant B as Bob (App)

    A->>S: Darf ich Bob anrufen?<br/>(Anfrage angenommen, kann Anrufe)
    A->>S: Zugangsdaten für den Vermittlungsdienst<br/>(24 h gültig, ohne Konto-Kennung)
    A->>S: Einladung, verschlüsselt für Bob,<br/>signiert mit Alices Identitätsschlüssel
    alt Bobs App ist offen
        S-)B: Einladung über den privaten Kanal
    else Bobs App ist geschlossen
        S->>S: Versiegelte Einladung bereithalten<br/>(höchstens 2 Minuten)
        S->>P: Nur Art, Chat-Kennung, Anruf-Kennung
        P-)B: Telefon klingelt (Systembildschirm)
        B->>S: Einladung abholen, wird dabei gelöscht
    end
    B->>B: Signatur prüfen:<br/>ungültig heißt kein Klingeln
    B->>S: Annahme, verschlüsselt und signiert
    S-)A: Annahme weiterreichen
    A->>T: Gespräch, Ende-zu-Ende verschlüsselt
    T->>B: Weiterreichen, ohne Protokoll
    Note over T,B: Weiterleitung abgeschaltet: direkte Verbindung,<br/>dann sieht das Gegenüber die IP-Adresse`,
    },
];
