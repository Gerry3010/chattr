# Chattr MCP-Server für Agents — Plan + Verwendungs-Doku

_Stand 2026-07-12, geplant von Linux-Claude (Lead). Status: **UMGESETZT**
(Migration `00038_mcp_agent_chats.sql`, `mcp_server/`, Client-UI + Auto-Join —
alle „Offene Fragen" unten sind entschieden und eingebaut). Ursprung:
Backlog-Wunsch „MCP-Server, über den Linux-Claude und Mac-Claude direkt
miteinander chatten können"._

## 0. Token-Binding statt QR-Join (Gerrys Verfeinerung, umgesetzt)

Der ursprüngliche Plan sah vor, dass Gerry jedem Agent-Chat manuell per
Group-QR beitritt. Stattdessen bindet ein **von Gerry in der App geminteter
MCP-Token** (Settings > MCP agents > „Mint new token") einen Agent-Chat direkt
an sein Konto: `chattr_ensure_project_chat` erstellt den Chat, ruft dann die
RPC `bind_mcp_chat(chat_id, token)` — setzt `chats.is_mcp = true` und
`chats.mcp_owner_id = <Gerrys User-ID>`. Gerrys App hat dafür einen
**Auto-Join-Reconciler** (`McpAutoJoinController`, läuft bei App-Start/Resume):
findet über eine RLS-Owner-Discovery-Policy Chats mit `mcp_owner_id = auth.uid()`,
in denen er noch kein Mitglied ist, generiert automatisch einen Keypair und
joint headless (`pending_chat_members`) — der Agent-Chat-Admin approved
automatisch (Policy: `mcp_owner_id` + `*-claude`-Usernamen). Der Chat erscheint
danach **standardmäßig gemutet** in der versteckten „MCP-Chats"-Zeile auf dem
Homescreen (Pull-down zum Aufdecken, wie WhatsApps archivierte Chats) statt in
der normalen Liste. Details: `supabase/migrations/00038_mcp_agent_chats.sql`,
`lib/features/mcp/`, `lib/screens/chat/mcp_chat_list_screen.dart`.

E2E-Grund dafür, dass es überhaupt einen Join-Schritt braucht (statt reiner
Server-Freigabe): der Server sieht nur Ciphertext. Der Token bindet den Chat
nur für die **Sichtbarkeit** (RLS-Discovery); zum **Lesen** muss Gerrys App
trotzdem ein echtes Verschlüsselungs-Mitglied mit eigenem Keypair werden.

## 1. Ziel

Ein MCP-Server, der Chattr als **vollwertiger E2E-Client** für Agents nutzbar macht.
Primärer Use-Case: **Linux-Claude ↔ Mac-Claude koordinieren sich per Chat** statt über
`docs/MAC_CLAUDE_*.md`-Dateien im Repo. Sekundär: Gerry kann die Projekt-Chats mit
seiner normalen App mitlesen/mitreden (inkl. Push!) — die Agents sind einfach weitere
Chat-Mitglieder.

**Kernkonzept (Gerrys Vorgabe): ein Chat pro Projekt.** Jedes Projekt bekommt einen
Gruppenchat `agents:<projekt>` (z. B. `agents:chattr`, `agents:homepage`). So bleiben
Threads sauber getrennt und ein Agent kann pro Projekt gezielt zuhören.

## 2. Warum Gruppenchats (nicht 1:1)

- **1:1-Chats sind remote nicht joinbar** — sie entstehen nur per QR-Scan (Kamera).
- **Group-Join geht headless:** Der Joiner braucht nur die `chat_id`, generiert seinen
  per-Chat-Keypair und inserted in `pending_chat_members`
  (`pending_chat_members_repository.dart:14`); der Admin approved
  (`approveMember`, :68) → Row wandert nach `chat_members`. Genau dieser Flow ist
  MCP-tauglich.
- Bonus: System-Messages (joined/removed/promoted) funktionieren seit dem
  Edge-Fn-Fix (v3-Hybrid) auch für Agents; Gerry sieht in der App, wenn ein Agent joint.

Die `chat_id` ist **nicht geheim** (Kenntnis erlaubt nur einen Join-*Request*, der
Admin-Approve braucht). Sie darf daher in eine Registry-Datei im jeweiligen
Projekt-Repo: **`.chattr-agents.json`** im Repo-Root:

```json
{ "project": "chattr", "chat_id": "<uuid>" }
```

Damit findet Mac-Claude den Projekt-Chat ohne Out-of-band-Kanal. Zusätzlich
(2026-07-12) trägt jeder Tool-Call, der einen Chat erstellt/entdeckt, denselben
Eintrag auch in eine **globale** Registry ein — `~/.claude/chattr-agents.json`,
`{"chattr": "<uuid>", "homepage": "<uuid>", ...}` — da der MCP-Server
maschinenweit registriert ist, nicht nur innerhalb eines Repo-Checkouts. Ein
Agent muss also nicht im jeweiligen Projekt-Verzeichnis stehen, um dessen Chat
per `project`-Namen anzusprechen.

## 3. Architektur

- **Node/TypeScript, stdio-MCP** — Struktur-Vorbild: der `craft-cms`-MCP-Server im
  Homepage-Repo (`mcp-server/`).
- **Vollwertiger Client, KEIN Service-Role-Key:** `supabase-js` + Anon-Key,
  `auth.signInAnonymously()` (wie `auth_repository.dart:8`) + Profil-Row mit Username.
  Ein Konto **pro Maschine/Agent**: `linux-claude`, `mac-claude` (Konvention:
  Suffix `-claude`, damit Agent-Accounts erkennbar sind).
- **Krypto = 1:1-Wiederverwendung von `web_crypto/src/crypto/`** (hybrid-kem.ts,
  aes-gcm.ts, hkdf.ts, mlkem.ts, x25519.ts — mlkem\@2.7.0 + @noble/curves\@1.8.1).
  Diese Lib ist die byte-identische Referenz des App-Clients und wurde bereits
  erfolgreich in die Edge-Fn `insert-system-message` portiert. Envelope v3:
  `{"v":3,"alg":"hybrid-kem:aes-gcm","ek":b64,"msg":b64(nonce12||ct||tag16)}`;
  Public-Key-Blob pro Chat-Member: `{"x":b64(X25519),"m":b64(ML-KEM-768 ek)}`.
  Interop-Tests gegen `web_crypto/testdata/` sind Pflicht.
- **State-Dir pro Maschine** (z. B. `~/.config/chattr-agent/`), **nie im Repo**:
  - `session.json` — Supabase-Session (Refresh-Token) für stabile Identität
  - `keys/<chat_id>.json` — per-Chat-Private-Keys (X25519 priv + ML-KEM dk)
  - `store.sqlite` — **Plaintext-Verlauf**. Zwingend: `mark_message_read()` cleart
    den Server-Ciphertext, die lokale Kopie ist danach die einzige (gleiches Modell
    wie die App).
- **Empfang:** MVP = Poll auf `messages` (`recipient_id = me`), decrypt → lokal
  persistieren → `mark_message_received`/`mark_message_read`-RPC (Reihenfolge wie
  `messages_repository.dart:160/:203`). Für `chattr_wait` zusätzlich der
  Realtime-Kanal `user:<userId>` (Event-Bus, `NewMessageEvent`).
- **Senden:** pro Empfänger verschlüsseln (ein Row je Recipient, gemeinsame
  Message-Id — Schema wie `messages_repository.dart:70-103`), `message_type: 'user'`.

## 4. MCP-Tools (v1)

| Tool | Zweck |
|---|---|
| `chattr_status` | Wer bin ich, Session ok, bekannte Projekt-Chats + Unread-Zähler |
| `chattr_init {username}` | Einmalig: anonymes Konto + Profil anlegen |
| `chattr_ensure_project_chat {project}` | Gruppenchat `agents:<project>` finden oder erstellen (Ersteller = Admin); liefert `chat_id` für die Registry-Datei |
| `chattr_join {chat_id \| project}` | Join-Request: Keypair generieren, `pending_chat_members`-Insert |
| `chattr_pending {project}` / `chattr_approve {project, user_id}` | Admin: Requests einsehen/freigeben (nur `*-claude`-Usernames auto-approven, Rest an Gerry melden) |
| `chattr_send {project, text, reply_to_id?}` | Nachricht senden (per-Recipient-Encrypt, inkl. Reply-Preview-Logik) |
| `chattr_fetch {project?}` | Neue Nachrichten holen: decrypt → lokal speichern → Server-Ciphertext clearen; Rückgabe chronologisch mit Sender-Name |
| `chattr_history {project, limit}` | Verlauf aus dem lokalen Store (Server hat nichts mehr) |
| `chattr_wait {project, timeout_s}` | Long-Poll via Realtime (max. ~300 s), gibt neue Nachrichten zurück oder Timeout |

Bewusst NICHT in v1: Media, Reactions, Edits, TTL — Agents brauchen erstmal Text.
(Media wäre v2: gleiche Envelope-Pipeline, nützlich für Screenshots von Mac-Claude!)

## 5. Verwendungs-Doku (Linux-Claude & Mac-Claude)

### Setup (einmalig pro Maschine)

Server ist **global** registriert (`--scope user`) — verfügbar in jeder
Claude-Code-Session, unabhängig vom aktuellen Arbeitsverzeichnis. Config liegt
darum außerhalb jedes Repos, an einem festen Ort:

```bash
cd mcp_server && npm install && npm run build

mkdir -p ~/.claude
cp .env.example ~/.claude/chattr-agent.env && chmod 600 ~/.claude/chattr-agent.env
# SUPABASE_URL / SUPABASE_ANON_KEY / AGENT_USERNAME / MCP_TOKEN eintragen

claude mcp add chattr-agent --scope user -- node "$(pwd)/build/mcp_server/src/index.js"
```

Erstlauf: `chattr_init {username: "linux-claude"}` bzw. `"mac-claude"`. Danach hält
`session.json` die Identität — **nie neu initialisieren**, solange die Session gilt
(sonst neues Konto = neue Identität, alte Chats verwaist).

Keys/lokaler Store bleiben im State-Dir (`~/.config/chattr-agent/<profile>/`)
— nichts davon in irgendeinem Repo.

**Projekt→Chat-Zuordnung ist zweifach getrackt:** die repo-lokale
`.chattr-agents.json` (committed, für wer auch immer das Repo checkt out)
*und* eine globale `~/.claude/chattr-agents.json` (`{"projekt": "chat_id"}`,
automatisch gepflegt) — damit ist ein Projekt-Chat per Namen erreichbar, auch
ohne im jeweiligen Repo zu stehen (Gerrys Wunsch, 2026-07-12: „zu jedem
Projekt einen Chat aufmachen/weiterschreiben können").

### Typischer Flow (Beispiel: Chattr-Projekt)

1. **Gerry:** mintet in der App (Settings > MCP agents) einen Token pro Agent
   (Label z. B. „linux-claude", „mac-claude") — einmalig sichtbar. **Weitergabe
   über einen bestehenden Agent-Chat** (E2E-verschlüsselt, erreicht alle
   Agenten in dem Chat auf einen Schlag) statt über eine Claude-Code-Session
   selbst, die sonst Teil des Sitzungs-Transkripts würde. In
   `~/.claude/chattr-agent.env` als `MCP_TOKEN` eintragen.
2. **Linux-Claude (Lead):** `chattr_ensure_project_chat {project: "chattr"}` →
   erstellt den Chat, bindet ihn per `MCP_TOKEN` an Gerry, trägt `chat_id` in
   beide Registries ein (repo-lokal committen + global).
3. **Mac-Claude:** `chattr_join {project: "chattr"}` — löst über die globale
   oder repo-lokale Registry auf, kein manuelles Chat-ID-Suchen nötig.
4. **Linux-Claude:** `chattr_approve {project: "chattr", user_id: <mac>}`
   (Username-Check!).
5. Ab dann: `chattr_send` / `chattr_fetch` / `chattr_wait`. Gerrys App joint
   den gebundenen Chat automatisch im Hintergrund (`McpAutoJoinController`,
   still, standardmäßig gemutet) — kein manuelles QR-Scannen mehr nötig.

**Ausnahme (2026-07-12):** ein Chat, der bereits an eine ANDERE Owner-Identität
gebunden ist (z. B. ein alter Test-Account), kann nicht per `bind_mcp_chat`
umgebunden werden — der neue Owner muss diesen einen Chat manuell joinen
(normaler `pending_chat_members`-Flow, ein Agent approved). Betrifft nur
bestehende Chats von vor einem Identitätswechsel; neue Chats binden sich
automatisch an den Token-Owner.

### Nachrichten-Konventionen (damit es koordinierbar bleibt)

- **Eine Task = eine Nachricht**, Antworten als **Reply** darauf (Thread-Bezug).
- Status-Präfixe: `TASK:`, `DONE:`, `BLOCKED:`, `FYI:`, `Q:` — maschinenlesbar genug
  für beide Seiten, menschenlesbar für Gerry.
- Kein Ping-Pong: nur senden, wenn es neuen Informationsgehalt gibt; offene Fragen
  an Gerry gehen weiterhin an Gerry, nicht in den Agent-Chat.
- Repo bleibt Quelle der Wahrheit: Der Chat koordiniert („PR #12 ist offen, bitte
  Review"), er ersetzt keine Doku/Commits.

### Schedules & Loops (Zuhören)

`chattr_wait` ist seit 2026-07-12 **Realtime-getrieben** (derselbe
`user:<id>`-Broadcast-Kanal, den die App selbst nutzt — kein 2-s-Poll mehr,
siehe `mcp_server/src/realtime.ts`). Zwei Rezepte je nachdem, ob eine
Claude-Code-Session gerade offen ist — **kein** Rezept weckt eine Session auf,
die nicht schon läuft (bewusste Scope-Entscheidung, siehe „Offene Fragen").

- **Passiv — Cron, Session bleibt frei für andere Arbeit:**
  ```
  CronCreate({
    cron: "7,22,37,52 * * * *",   // alle 15 min, off-minute
    prompt: "Ruf chattr_fetch für die bekannten Projekt-Repos auf: " +
            "~/Sync-Projekte/Chattr2/chattr (Projekt 'chattr'), " +
            "[weitere Repos hier eintragen]. Bei neuen Nachrichten: gemäß " +
            "TASK:/DONE:/BLOCKED:/FYI:/Q:-Konvention verarbeiten und ggf. " +
            "per chattr_send antworten. Ohne neue Nachrichten still bleiben.",
    recurring: true,
  })
  ```
  **Wichtig:** `CronCreate`-Jobs sind **session-gebunden** — sie verschwinden,
  sobald diese Claude-Code-Session endet, und laufen maximal 7 Tage. Kein
  Ersatz für einen echten Daemon, aber genau im gewünschten Scope (kein
  Aufwachen ohne laufende Session). Nach jedem Sessionstart neu anlegen, wenn
  weiter passiv mitgehört werden soll.
- **Aktiv — Warteschleife, near-instant, bindet die Session:** Während einer
  laufenden Zusammenarbeitsphase in einer Schleife auf `chattr_wait` hängen,
  statt zu pollen:
  ```
  chattr_wait({ project: "chattr", timeout_s: 270 })
  // → nicht-leer: Nachrichten verarbeiten, ggf. chattr_send antworten
  // → leer (Timeout): einfach nochmal aufrufen
  ```
  Als `/loop`: Prompt ruft `chattr_wait` auf, verarbeitet ein Ergebnis, und
  plant über `ScheduleWakeup` mit kurzer Verzögerung (~10 s) den nächsten
  Durchlauf — dank Realtime-Backing kommt eine Antwort praktisch sofort an,
  nicht erst nach dem alten 2-s-Tick.
- **Eskalation:** Wenn ein Agent auf eine `Q:`-Nachricht über mehrere
  Cron-Zyklen/Wait-Durchläufe keine Antwort bekommt, den Menschen informieren
  (Gerry sieht den Chat ohnehin in der App).

## 6. Volatilität: Access weg = alles weg (Gerry, 2026-07-12)

Chattrs Modell ist radikal: Server-Ciphertext wird nach Read gecleart, der lokale
Store ist die **einzige** Kopie. Geht das State-Dir verloren (Session + per-Chat-Keys
+ `store.sqlite`), ist Verlauf UND Identität weg — für Agents wie für echte User.
Das ist das bekannte **Restore/Multi-Device-Backlog-Thema** und wird hier bewusst
mitgedacht statt ignoriert:

- **Agents (pragmatisch, v1):** Agent-Chats sind Koordination, kein Archiv — der
  Re-Bootstrap ist billig: neues `chattr_init` → `chattr_join` via Registry-Datei →
  Approve. Verlust ist ärgerlich, nicht katastrophal. Trotzdem: State-Dir liegt an
  einem backup-üblichen Ort (`~/.config/chattr-agent/`) und gehört in die normale
  Maschinen-Sicherung.
- **`chattr_export_state` / `chattr_import_state` (v1.5):** kompletter State als
  **eine passphrase-verschlüsselte Bundle-Datei** (Session-Refresh-Token +
  per-Chat-Keys + Plaintext-Store, AES-GCM via bestehender Krypto-Lib). Damit ist
  Umzug/Backup ein Einzeiler.
- **Strategischer Nebeneffekt:** Dieses Bundle-Format ist der **Prototyp für das
  User-Restore-Feature der App** (Backlog „erst Restore durchdenken, dann
  Multi-Device"). Der MCP-Server ist der ideale Ort, das Format risikofrei zu
  erproben — gleiche Krypto, gleiche Datenstruktur (Keys + lokale DB), kein
  App-Release nötig. Wenn es sich bewährt, übernimmt die App Export/Import desselben
  Formats (Datei teilen bzw. später QR/Cloud-Kanal fürs Multi-Device-Sync).

## 7. Offene Fragen — entschieden (2026-07-12)

1. **Ablageort:** `mcp_server/` im Chattr-Repo (teilt sich `web_crypto/`). ✅
2. **Direkt gegen Prod?** Ja — Rollout-Gate siehe unten. ✅
3. **Gerry Mitglied in jedem Agent-Chat?** Ja, automatisch via
   `McpAutoJoinController` (Token-Binding statt manuellem QR-Join, siehe
   Abschnitt 0). ✅

## 8. Umsetzungs-Stand

1.–5. (Gerüst, Krypto-Port, Chats, Send/Fetch/History, Client-Auto-Join) — **fertig.**
6. **Lokal E2E verifiziert** (`mcp_server/test/two_agent_e2e.test.ts`, zwei
   Agent-Accounts, echter stdio-Transport, voller Rundtrip inkl. idempotentem
   `ensure_project_chat` und Read-Watermark). Krypto-Interop-Vektor grün
   (`mcp_server/test/crypto_interop.test.ts`).
7. **Prod-Rollout:** Migration `00038` + `agents:chattr`-Bootstrap — live,
   am echten Galaxy end-to-end verifiziert (Token-Mint, Auto-Join, versteckte
   Zeile, Nachricht entschlüsselt angezeigt). Details:
   [[backlog-mcp-server-agents]] (Memory).
8. **`chattr_wait` auf Realtime umgestellt (2026-07-12):** kein 2-s-Poll mehr —
   echte Subscription auf denselben `user:<id>`-Broadcast-Kanal, den die App
   nutzt (`mcp_server/src/realtime.ts`). Verifiziert durch
   `mcp_server/test/realtime_wait.test.ts` (Latenz-Assertion: Zustellung
   deutlich unter der alten 2000-ms-Poll-Grenze) + manueller Smoke-Test gegen
   Prod. Cron-/Loop-Rezepte für passives bzw. aktives Zuhören: siehe
   „Schedules & Loops" oben.

Größtes verbleibendes Risiko war Krypto-Interop — durch die Test-Vektoren und
den bereits zweifach erprobten Port abgesichert, verifiziert grün.

— Linux-Claude
