# Chattr – Triage & Remediation-Roadmap

## Kontext

Das Projekt (Flutter + Supabase, E2E-verschlüsselter Chat) lag länger liegen. Ziel dieses
Durchgangs: einmal systematisch über Bugs und Verbesserungspotenzial schauen. Fünf parallele
Review-Agenten haben Krypto, Messages/Sync, Realtime/State, Supabase-Backend und UI/Code-Health
durchgegangen (~40 Funde). Dieser Plan konsolidiert und priorisiert sie als Roadmap, die wir
**etappenweise** abarbeiten.

**Rahmenbedingung: Pre-Release, keine echten Nutzer/Daten.** → Wir fixen *forward*: keine
Key-Rotation, keine Daten-Migration, alter Legacy-Krypto-Pfad (RSA) darf **komplett entfallen**.
Da alle Daten irrelevant sind und der Nutzer freie Hand gibt, darf das **Supabase-Backend frei umstrukturiert**
werden (Migrationen konsolidieren/neu schneiden statt nur anhängen, RLS/Trigger/Funktionen überarbeiten) — die
lokale DB wird per `supabase db reset` neu aufgebaut.

**Zusätzliche Ziele dieses Durchgangs (vom Nutzer gesetzt):**
1. **Post-Quantum-Umstellung:** RSA wird durch **Hybrid X25519 + ML-KEM-768** ersetzt (Stage 5). Vorlage ist
   das bereits funktionierende Schwester-Projekt **passbubble** (`~/Sync-Projekte/GO-Projekte/Password-Manager`),
   inkl. Web-Support — dessen Krypto-Kern wird vendored statt neu implementiert.
2. **Umfassende Tests:** So vollständig wie möglich über **Supabase** (RLS/DB-Funktionen/Edge-Functions) **und
   Flutter** (Unit/Widget/Integration) — bewusst als Bug-Findungs-Netz für die hier gelisteten Funde und als
   Regressionsschutz der Refactors. Tests werden **pro Stage mitgeschrieben**, Stage 6 bündelt Strategie & Lücken.

**Legende:** ✅ = von mir im Code verifiziert · ⚠️ = Agent-Befund, vor Umsetzung kurz gegenprüfen.

---

## Stage 1 — Kritisch: Security & Datenverlust (P0)

### 1.1 ✅ Schwacher Zufall bei AES-Keys & GCM-Nonces — **bricht E2E effektiv**
`lib/core/security/message_encryption_service.dart:136-145` (`_randomBytes`)
Fortuna wird mit 32 Bytes geseedet, die **alle** denselben Wert `microsecondsSinceEpoch % 256`
haben → ~8 Bit Entropie. Damit werden AES-256-Keys *und* GCM-Nonces erzeugt → vorhersagbar/Kollisionen.
- **Fix (Interim):** Seed mit `Random.secure()` füllen (exakt das Muster, das `lib/core/crypto/rsa_keygen_io.dart:23-28`
  bereits korrekt nutzt). Idealerweise eine gemeinsame `secureRandomBytes()`-Helper-Funktion.
- **Hinweis:** Stage 5 (PQC) ersetzt diesen Service ganz und lagert die Zufallserzeugung an Go/Web-Crypto aus →
  der Bug verschwindet dann strukturell. 1.1 ist trotzdem **sofort** zu machen (einzeilig), falls Stage 5 nicht
  zuerst kommt; jeder verbleibende AES-Key/Nonce-Gen in Dart muss sicheren Zufall nutzen.
- Pre-Release: kein Re-Encrypt nötig.

### 1.2 ✅ Daten-Wipe bei transientem Session-Fehler
`lib/core/init/app_init.dart:173-237` (`_checkAuthState` / `_deleteData`)
`refreshSession` im try/catch setzt bei **jedem** Fehler (inkl. Netzwerk-Timeout/Offline) `response = null`
→ Fall-through zu „User not found" → bei vorhandenem Key `return true` → `_deleteData()` löscht Encryption-Key,
SQLite-DB und via `storage.deleteAll()` **alle** privaten Chat-Keys. Ein einziger Offline-Start zerstört
unwiederbringlich alle Chats/Keys.
- **Fix:** Netzwerk-/transiente Fehler vom echten „kein gültiger User"-Fall trennen. Nur wipen, wenn der
  Server eindeutig „keine Session" sagt — nicht bei Exceptions. Bei Refresh-Fehler: bestehende Session
  behalten und später erneut versuchen.

### 1.3 ✅ Doppelte, zu permissive RLS-SELECT-Policy auf `messages`
`supabase/migrations/00005_row_level_security.sql:199-209`
Zwei SELECT-Policies koexistieren; Postgres OR-t permissive Policies, daher hebt die lockere
(`recipient_id = auth.uid() OR sender_id = auth.uid()`) die strikte (`recipient_id = auth.uid()`) auf.
Sender kann so alle Per-Recipient-Zeilen lesen. Analog doppelte INSERT-Policies (`:212` & `:224`).
- **Fix:** Neue Migration `00010_*.sql`, die die lockere SELECT-Policy und die redundante INSERT-Policy
  droppt; strikte recipient-only SELECT + die „insert for all members"-INSERT behalten.

### 1.4 ⚠️ Edge-Functions ohne Aufrufer-Autorisierung
`supabase/functions/insert-system-message/index.ts`, `supabase/functions/setup-env/index.ts`
- `insert-system-message` nutzt den **Service-Role-Client (umgeht RLS)** und prüft den Aufrufer nicht →
  jeder gültige JWT kann „System"-Nachrichten in beliebige `chat_id` injizieren. Zusätzlich Referenz auf
  **nicht existierende Spalte** `chat_members.accepted` (Schema `00001` hat sie nicht) → Fallback-Pfad bricht.
- `setup-env` schreibt Secrets in den Vault ohne Autorisierungs-Check.
- `console.log(Deno.env.toObject())` (`insert-system-message:24`) dumpt Secrets in die Logs.
- **Fix:** Caller-Autorisierung erzwingen (Admin-/Mitgliedschafts-Check gegen `auth.uid()`); `accepted`-Query
  korrigieren; Env-Dump entfernen. `verify_jwt` in `config.toml` explizit setzen.

### Secrets-Hygiene (bestätigt, kein Akut-Fix)
`.env`, `fcm-private-key.json`, `supabase/functions/.env` liegen lokal, sind **gitignored und nicht getrackt**
(verifiziert). `supabase-docker/.env.example` ist getrackt, enthält aber nur Supabase-Default-Platzhalter/Demo-Keys
→ harmlos. Kein Leak. (Der Agent-Befund „FCM-Key committed" war falsch.)

---

## Stage 2 — Datenkorrektheit & Sync (P1)

- **2.1 ✅ Invertierte „received"-Bedingung.** `lib/features/messages/messages_controller.dart:628-629`:
  markiert offline empfangene Nachrichten nur dann als received, wenn sie *schon* received sind (`!= null`
  statt `== null`/unbedingt) → Delivery-Status für den Sender bricht. Bedingung umdrehen.
- **2.2 ⚠️ Reaktions-Cache lokal nie bereinigt.** `message_reactions_repository.dart:99-112`
  (`_syncReactionsToLocal`) fügt nur ein, löscht entfernte Reaktionen lokal nie → entfernte Reaktionen
  tauchen beim Offline-Fallback wieder auf. Diff/Delete ergänzen.
- **2.3 ⚠️ `markChatAsDeleted` ist leerer Stub.** `chats_local_repository.dart:97` → `chatDeleted`-Events
  wirken lokal nicht, Chat erscheint nach Reload wieder. Implementieren.
- **2.4 ⚠️ N+1 RPC beim Laden von Reaktionen.** `message_reactions_controller.dart:256-264` ruft pro Message
  eine RPC; Batch-Methoden (`getReactionsForMessages` / DAO `inFilter`) existieren bereits → umstellen.
- **2.5 ⚠️ `markAsRead` / Server-Ciphertext-Clear nicht atomar** (`messages_controller.dart:684-692`).
  Reihenfolge so anordnen, dass lokaler Read-State vor dem serverseitigen Clear persistiert wird; `firstWhere`
  braucht `orElse`.

---

## Stage 3 — Event-System-Refactor: „Main Bus" (P1, ersetzt die Einzel-Leaks)

**Entscheidung: Voll-Konsolidierung.** Statt die 7 Einzel-Leaks einzeln zu flicken, ziehen wir das gesamte
Realtime-System auf **ein** Gateway mit **einem** typed Event-Stream zusammen. Damit werden die meisten
Stage-3-Symptome *strukturell* obsolet. Vollständige Ist-Inventur siehe **Anhang A**.

**Zielbild:**
- **Ein `RealtimeGateway` (der Main Bus)** besitzt das gesamte Channel-Lifecycle. Niemand sonst öffnet je
  einen `RealtimeChannel`.
- **Genau ein In-Process-Layer:** ein typed `Stream<BusEvent>`. Der doppelte `on/off`-Handler-Map-Layer
  **und** der parallele `eventStream` werden auf **einen** reduziert. (Aktuell hat `eventStream`/`eventStreamOf`
  **null Consumer** — alle nutzen `on()`; wir drehen das um auf den Stream, weil er sich sauber an
  Riverpod-autoDispose koppeln lässt.)
- **Lifecycle an Riverpod gekoppelt:** Consumer hören via autoDispose-`StreamProvider`/`ref.listen`. Kein
  manuelles `on/off` mehr → die „Handler nie deregistriert"-Leaks (alt 3.1) können nicht mehr entstehen.

**Channel-Konsolidierung (6 → 2):**
- **Bleibt:** `user:<userId>` (Broadcast, alle DB-Trigger-Events) und `chat:<chatId>:typing` (Presence —
  Supabase-bedingt nicht zusammenlegbar, aber vom Gateway lifecycle-verwaltet, autoDispose).
- **Entfällt:** `message_reactions:<messageId>`, `chat_reactions:<chatId>`, `table-db-changes`,
  `realtime:<table>`-Helper. Reaktionen und Profil-Changes werden **serverseitig per DB-Trigger** als Events
  auf `user:<userId>` gebroadcastet — exakt das Muster von `notify_members_new_message` (`00003`).

**Arbeitspakete:**
1. **Server:** Neue Migration(en) mit Trigger-Funktionen `notify_reaction_change` (auf `message_reactions`,
   INSERT/DELETE → an alle Chat-Mitglieder auf `user:<id>`) und `notify_profile_change` (auf `profiles`,
   UPDATE/DELETE → an relevante Mitglieder). Payload-Shape analog bestehender Events. Neue `EventType`s
   `reactionChanged`, `profileChanged` in `lib/core/events/event_types.dart` + Payload-Modelle.
2. **Gateway:** `EventBusService` → `RealtimeGateway` umbauen: besitzt `user:<id>`-Broadcast + Typing-Presence;
   exponiert `Stream<BusEvent>` (+ gefilterte Helfer `eventsOf<T>()` / `eventsForChat(chatId)`).
   `dispose()` awaitet `unsubscribe()` sauber (alt 3.7). Re-Injection-Loop **streichen**: `GlobalMessageHandler`
   entschlüsselt und emittiert **in-process** in den Stream statt via `_channel.trigger(local:true)`.
3. **Consumer migrieren:** `ChatsController`, `GlobalMessageHandler`, `NotificationController`,
   `MessagesController` von `eventBus.on(...)` auf `ref.listen`/Stream-Subscription mit autoDispose umstellen.
   Reaktions- & Profil-Consumer (heute eigene PostgresChanges-Controller) auf die neuen Bus-Events umstellen →
   `message_reactions_controller.dart`-Subscriptions, `profiles_controller.dart`-Channel und
   `realtime_subscription.dart` entfernen. Damit fallen alt **3.2 / 3.3 / 3.5** weg.
4. **Enum-Mismatches bereinigen:** `messageDelete` (emittiert, **kein Consumer**) → Consumer ergänzen oder
   Event entfernen. `memberStatusChanged` wird nur lokal aus `newChat` synthetisiert, während Trigger
   `membershipChanged` senden → Pfad geradeziehen (ein Event-Typ, ein Consumer).
5. **Init/Lifecycle entkoppeln** (zieht alt 3.6 mit): `ChatsController._init` (Biometrie-Prompt) von
   `ref.watch(eventBusProvider/authControllerProvider)`-Rebuilds trennen, damit nicht jeder Rebuild neu
   initialisiert/promptet.

**Verbleibt separat (gehört nicht in den Bus-Refactor):**
- **Alt 3.4 — Stale Supabase-Client nach `reinitialize()`** (`supabase_client_provider.dart:4`): unabhängiges
  Lifecycle-Problem, bleibt eigener Fix (Provider nach Reinit invalidieren). → bleibt in Stage 3 als **3.x**.

---

## Stage 4 — UI-Robustheit & Polish (P2)

- **4.1 ⚠️ QR-Scanner hängt im Processing / erzeugt still falschen Chat.** `qr_scanner_screen.dart:79-126`:
  ungeschütztes `throw` lässt UI im Lade-Zustand hängen; jeder Fehler im Join-Pfad wird als „User-ID"
  interpretiert → falscher 1:1-Chat. try/finally + Fehlerdifferenzierung.
- **4.2 ⚠️ Toter QR-Scan-Handler.** `chat_list_screen.dart:147-155` zeigt rohen Map-Dump
  `'User ID: $result'` statt zu navigieren (TODO). Verkabeln + lokalisieren.
- **4.3 ⚠️ Notification-Deeplink wirft beim Cold-Start.** `notification_navigation_handler.dart:59-83`:
  `firstWhere(... orElse: throw)`, wenn Chat noch nicht im Memory → Tap macht still nichts. Chat bei Bedarf
  nachladen statt werfen.
- **4.4 ⚠️ FCM-Payload selbstgebautes `key=value&`-Encoding** (`fcm_service.dart:255-269`) bricht bei `=`/`&`
  in Werten → falsche/leere `chat_id`. Auf `jsonEncode/Decode` umstellen.
- **4.5 ⚠️ Null-Assert auf `_messageToSend`** in `chat_view_screen.dart:96-98` (Keyboard-Send) → möglicher Crash.
- **4.6 ⚠️ `getInitials` RangeError** bei leerem Anzeigenamen (`chat_list_screen.dart:379-383`). Guard.
- **4.7 ⚠️ Rohe, nicht lokalisierte `Error: $e`-Snackbars** (mehrfach in `chat_detail_screen.dart`,
  `chat_list_screen.dart`) trotz easy_localization. Lokalisieren.

---

## Stage 5 — Post-Quantum-Hybrid-Migration (X25519 + ML-KEM-768), ersetzt RSA

**Ziel:** RSA-OAEP-Key-Wrapping durch **Hybrid X25519 + ML-KEM-768** ersetzen. Pre-Release → RSA und Legacy
v1/v2 **ersatzlos raus**, neues Payload-Format `v3`. Architektur bleibt KEM-DEM (nur der Wrap-Schritt ändert sich).

**Vorlage & Wiederverwendung (passbubble, verifiziert):** `~/Sync-Projekte/GO-Projekte/Password-Manager`
hat exakt dieses Schema produktiv inkl. Web. Wir **vendoren den bewährten Krypto-Kern** statt neu zu bauen:
- **Web:** TS-Krypto (`hybrid-kem`/`mlkem`/`x25519`/`aes-gcm`/`hkdf`, npm: `mlkem`, `@noble/curves`, `hash-wasm` +
  Web Crypto API) → per **esbuild** zu `web/chattr_crypto.js`, auf `globalThis` exponiert, **vor** `flutter_bootstrap`
  in `web/index.html` geladen; Aufruf aus Dart via `dart:js_interop`. (passbubble: `flutter_app/web_crypto/entry.mjs`,
  `flutter_app/lib/core/crypto/ml_kem_web.dart`.)
- **Nativ:** Go (`cloudflare/circl`) als C-shared-lib → Dart **FFI** (`ml_kem.dart`).
- **Facade:** `VaultCrypto` (nativ→FFI, web→js_interop, identisches Wire-Format) — 1:1 übernehmen.
- HKDF-`info`-Konstante auf Chattr anpassen (z.B. `"chattr-hybrid-kem-v1"`).

**Wire-Format (pro Empfänger):** `ephX25519Pub(32) ‖ mlkemCT(1088) ‖ nonce(12)+gcmCT`. Auto-Detektion per Länge.

**Chattr-Integration:**
- `MessageEncryptionService.encryptForAllMembers`: sicheren AES-256-Message-Key + Nonce erzeugen (Zufall via
  Krypto-Kern, **nicht** mehr `_randomBytes`), Plaintext **einmal** AES-GCM verschlüsseln, dann pro Mitglied
  `VaultCrypto.encryptDataKey(msgKey, member.x25519Pub, member.mlkemPub)`. Payload `{v:3, ek, iv, ct, tag}`
  (ct/tag geteilt, ek pro Empfänger).
- Decrypt: `VaultCrypto.decryptDataKey(ek, privX25519, privMlkem)` → msgKey → AES-GCM.
- **Löschen:** `lib/core/crypto/rsa_keygen*.dart`, RSA-Teile von `chat_key_pair_manager.dart`, alle OAEP-/Legacy-Pfade
  in `message_encryption_service.dart`. `pointycastle` als Krypto-Dependency entfällt für Messages.

**Schlüsselverwaltung — Per-Chat-Keypaare (Nutzer-Entscheidung, behält Kompartimentierung wie heute RSA):**
- Jeder **Chat** hat ein X25519- + ML-KEM-768-Keypair pro Mitglied (Ablösung der heutigen per-Chat-RSA-Keys).
  Key-Lookup bleibt chat-gebunden (`ChatKeyPairManager.getPrivateKey(chatId)` → jetzt zwei Privatschlüssel).
  Der passbubble-`VaultCrypto`-Facade bleibt identisch; nur der **Key-Lookup** wird per-Chat statt per-User
  (passbubble nutzt per-User — das ist die einzige Anpassung am vendored Kern).
- **DB-Migration** `00011_*`: Member-Keys in `chat_members` von RSA-`public_key` auf `pub_x25519` + `pub_mlkem768`
  (bytea/base64) umstellen. Private Keys verschlüsselt in Secure Storage pro Chat (`enc_priv_x25519:<chatId>`,
  `enc_priv_mlkem768:<chatId>`).
- **Key-Distribution:** beim Chat-Beitritt/Approve werden die beiden Public Keys des neuen Mitglieds verteilt
  (analog zum heutigen Member-Key-Flow über `chat_member_keys_repository.dart`).

**Verbleibende Krypto-Härtung (unabhängig von der Migration):**
- **5.a ⚠️ Decrypt-Fehler werden verschluckt** (`encryption_service.dart` + Controller → `null`). Logging/sichtbarer
  Fehlerzustand statt stillem Drop. Gilt auch im neuen Pfad.
- **5.b ✅ Biometrie-Gate ist Stub** (`biometric_auth_service.dart:39-42`) → **echtes Gate umsetzen**: Biometrie
  erzwingen wo verfügbar, sonst **App-Passcode-Fallback** (neuer Passcode-Setup-Flow + Verifikation). Schließt die
  Lücke, dass der lokale Key auf Desktop/Web ungeschützt ist. `EncryptionService` muss `requireBiometric`
  tatsächlich nutzen (heute immer `false`).
- **5.c ⚠️ Lokales AES-CBC ohne MAC** (`encryption_service.dart:34-77`) → auf GCM (konsistent zur Message-Schicht).
- **5.d ⚠️ `AndroidOptions(resetOnError: true)`** (`encryption_key_manager.dart:89-92`) kann Key still löschen.
- **5.e ⚠️ SECURITY-DEFINER-Funktionen ohne `search_path`** (`00006`/`00007`, Trigger `00002`/`00003`) → `SET search_path = ''`.

**Tests (integriert):** KAT-/Interop-Vektoren nach passbubble-Vorbild (committete `vectors.json`, **nativ↔web-Parität**),
Hybrid-Roundtrip, Tampering, Multi-Recipient, Fallback. Siehe Stage 6.

---

## Stage 6 — Umfassende Test-Suite (Supabase + Flutter) — Bug-Findungs-Netz

Ziel (vom Nutzer): **so vollständig wie möglich** testen, um die hier gelisteten Funde zu reproduzieren und die
Refactors abzusichern. Tests werden **pro Stage** mitgeschrieben; dieser Abschnitt ist Strategie + Lückenliste.

**Test-Infrastruktur (verifiziert lauffähig):**
- Docker läuft **ohne sudo** (User in `docker`-Gruppe), Supabase-CLI v2.105.0 vorhanden. → Lokale Supabase via
  `supabase start` (wendet `supabase/migrations` automatisch an, liefert lokale URL/Keys). **Alle Daten irrelevant**
  → Tests dürfen DB frei `supabase db reset`-en.
- `.env` für Tests auf lokale Instanz zeigen lassen (oder Test-`.env`).

**A. Aufräumen (Vorbedingung)**
- **6.1 ✅** Stale `analysis_errors.txt` / `analysis_output.txt` löschen (beziehen sich auf alten Code; aktuell
  `flutter analyze` = 0 Errors / 32 Warnings).
- **6.2 ⚠️** Debug-/Scratch-Tests entrümpeln: `debug_encryption_test.dart`, `simple_encryption_test.dart`,
  `pointycastle_direct_test.dart`, `key_comparison_test.dart` (voller `print`). `widget_test.dart` ist noch Counter-Stub.

**B. Supabase / Backend (gegen lokale Instanz, pgTAP oder SQL-Skripte mit `set role`/JWT-Claims)**
- **RLS-Policy-Tests:** Sender liest fremde Recipient-Zeilen **nicht** (Regression 1.3); recipient-only SELECT;
  Admin-Gates (Nicht-Admin kann keine Admin-Aktion); `messages` UPDATE nur durch Sender.
- **DB-Funktionen:** `mark_message_read`/`mark_message_received` (löscht nur eigene Zeile + nur `encrypted_content`),
  `toggle_message_reaction`, `get_*_reaction_summary`, `reassign_admin_on_leave`.
- **Edge-Functions:** `insert-system-message`/`setup-env` Authorization (Regression 1.4); `accepted`-Spalten-Fix;
  kein Secret-Dump im Log.
- **Trigger/Broadcast:** Event-Payloads korrekt, kein Plaintext-Leak; nach Event-Refactor (Stage 3) auch
  Reaction-/Profile-Broadcasts.

**C. Flutter Unit-Tests**
- **Krypto (Stage 5):** Hybrid-Roundtrip, **KAT-/Interop-Vektoren nativ↔web** (passbubble-Vorbild), Multi-Recipient,
  Tampering-Reject, Fallback; RNG-Entropie-Regression (1.1).
- **Sync/Messages:** Send→Decrypt, Missed-Message-Received-Quittung (2.1), Reaction-Local-Prune (2.2),
  `markChatAsDeleted` (2.3), `markAsRead`-Reihenfolge (2.5).
- **Event-Bus/Gateway (Stage 3):** Subscribe/Unsubscribe-Lifecycle, **keine Handler-Akkumulation**, Re-Login ohne
  Duplikate, nur 2 Channel-Typen aktiv.
- **Auth/Init:** `loginWithUsername`; Wipe-Logik feuert **nicht** bei transientem Refresh-Fehler (1.2).

**D. Flutter Widget-Tests**
- Login, Chat-Liste (`getInitials` leer → kein RangeError, 4.6), Chat-View (Keyboard-Send-State 4.5), Banners,
  QR-Scanner (kein Stuck-Processing 4.1).

**E. Flutter Integration-Tests** (`integration_test`, gegen lokale Supabase)
- **Voller E2E-Flow mit 2 Usern/Instanzen** (Nutzer-Wunsch — ans Ende, Stage 6): zwei separate
  Supabase-Clients + Key-Manager im selben Test simulieren zwei Geräte → beide **registrieren/login** →
  User A **legt Chat an** → User B **beitreten/approven** (inkl. Member-Key-Austausch X25519+ML-KEM) →
  A **schreibt verschlüsselte Nachricht** → B **empfängt & entschlüsselt** (PQC end-to-end) →
  **Reaktion + Read-Receipt** → (sobald implementiert) **Edit/Delete-Propagation**. Der „echte"
  Cross-User-Beweis, dass Auth + Realtime + PQC + Sync zusammenspielen.
- QR-Join-Flow; Offline→Resync (missed messages).

**F. Coverage & CI**
- `flutter test --coverage`; Backend-Test-Target in `Makefile`/Pipeline; Analyzer-Gate (0 Errors).
- **6.4** Die 32 Analyzer-Warnings (strict raw types / inference) aufräumen.

---

## Stage 7 — Feature-Vervollständigung (Nutzer-Auswahl)

Vier unfertige Features fertigstellen + ein neues Anti-Spam-Feature. Jeweils mit Tests (Stage 6).

- **7.1 Mitglied hinzufügen (QR) + Scan-Flow.** Stub-Dialoge in `chat_members_screen.dart:403` &
  `chat_detail_screen.dart:475` implementieren; QR-Scan→Chat/Beitritt in `qr_scanner_screen.dart:151` /
  `chat_list_screen.dart:148` fertigstellen. Behebt zugleich Bug **4.1/4.2**. Beim Hinzufügen: Member-Keys
  (X25519+ML-KEM, Stage 5) verteilen.
- **7.2 Mitglied entfernen / Zugriff widerrufen.** Admin entfernt Mitglied → `chat_members`-DELETE feuert bereits
  `chatDeleted`/`membershipChanged`. Sicherstellen, dass der Entfernte keinen Zugriff mehr hat (RLS bereits
  recipient-scoped) und die **Key-Rotation des Chats** angestoßen wird (neuer Chat-Key, an verbleibende Mitglieder
  verteilt), damit künftige Nachrichten für den Entfernten nicht entschlüsselbar sind. UI in `chat_members_screen`.
- **7.3 Nachricht bearbeiten + Löschen propagieren.** Edit: Sender ändert Inhalt (RLS „Senders can update"
  existiert) → re-encrypt pro Empfänger + `messageUpdate`-Event mit Inhalt. Delete-Propagation: **`messageDelete`
  bekommt einen Consumer** (heute keiner, siehe Anhang A.3/Stage 3) → entfernt die Nachricht lokal+UI bei allen.
- **7.4 Pending-Request zurückziehen.** `chat_members_controller.dart:200` umsetzen: User storniert eigene offene
  Beitrittsanfrage (`pending_chat_members`-DELETE, RLS „Users can view/manage own pending requests").
- **7.5 ⭐ Blockieren (Anti-Spam, neu).** User/Requests müssen blockierbar sein, damit kein wiederholtes
  Spam-Anfragen möglich ist:
  - **DB:** neue Tabelle `chat_blocks` (chat_id, blocked_user_id, blocked_by, created_at) + RLS (nur Admins
    verwalten, Betroffener sieht nichts).
  - **Enforcement:** `request_to_join`-Pfad (RLS-Policy „Users can request to join chats" + ggf. Funktion) prüft
    `chat_blocks` → blockierte User können **keine** neue Anfrage stellen.
  - **Flow:** „Request ablehnen **und** blockieren" als Admin-Aktion (entfernt aus `pending_chat_members` +
    Eintrag in `chat_blocks`); Unblock-UI.
  - Optional global (user-zu-user-Block) später; vorerst chat-scoped.

---

## Stage 8 — Nice-to-have-Features (Nutzer-Wunsch: alle)

- **8.1 Profilbilder / Avatars.** `profile_model.dart:7` (`imageUrl`) aktivieren; Upload + Anzeige in Chat-Liste
  und Nachrichten. Speicherung via **Supabase Storage** (`avatar_path` auf `profiles`). E2E-Abwägung: Avatar
  bewusst „public"-Bucket **oder** clientseitig verschlüsselt — Entscheidung beim Umsetzen.
- **8.2 Selbstzerstörende Nachrichten (TTL/ephemeral).** TTL pro Nachricht/Chat; nach Ablauf lokal + Server
  gelöscht. Baut auf Server-Cleanup (`MESSAGE_CLEANUP.md`): `expires_at`-Spalte + Server-Cron-Delete +
  clientseitiger Lösch-Timer + UI (Timer-Auswahl beim Senden).
- **8.3 Dark Mode.** Theming in `app.dart` (Light/Dark/System) + Persistenz (Settings); konsistent über
  `chatview`-Theme.
- **8.4 Nachrichtensuche.** **Clientseitig** über die lokale, entschlüsselte SQLite-DB (Server hat keinen Klartext) —
  Volltextsuche über `messages_local_repository` (LIKE/FTS5), Such-UI im Chat + chatübergreifend.

*(Weitere ROADMAP-Punkte — Screenshot-Schutz, Chat-Info-Seite, Animationen, allgemeine Key-Rotation — bleiben
bewusst in der ROADMAP, sofern nicht oben abgedeckt; sag Bescheid, falls auch gewünscht.)*

---

## Empfohlene Reihenfolge

0. **Test-Infra hochziehen:** `supabase start` (lokal, Migrationen anwenden), Test-`.env`, `flutter test` grün
   als Baseline. Stale Analyzer-Artefakte + Scratch-Tests weg (6.1/6.2).
1. **Stage 1** komplett (P0, Security/Datenverlust) — klein im Code, größte Wirkung. Jeweils mit Regressionstest.
2. **Stage 2** (Datenkorrektheit) — kleine, gezielte Fixes + Tests.
3. **Stage 5** (PQC-Hybrid-Migration) — ersetzt RSA; Krypto-Kern aus passbubble vendoren, KAT/Interop-Tests.
   (Macht den Interim-RNG-Fix 1.1 obsolet, daher früh.)
4. **Stage 3** (Event-System-Refactor) — größter Brocken; mehrteilig (Server-Migrationen → Gateway →
   Consumer-Migration → Cleanup), löst Realtime-Leaks als Klasse, mit Lifecycle-Tests.
5. **Stage 4** (UI-Robustheit) + restliche **Stage 5**-Härtung (5.a–5.e, inkl. echtes Biometrie-Gate 5.b).
6. **Stage 7** (Feature-Vervollständigung: Mitglied add/remove, Edit/Delete-Propagation, Request-Abbruch, Blocking).
7. **Stage 8** (Nice-to-have: Avatars, Self-Destruct, Dark Mode, Suche).
8. **Stage 6** Test-Suite verbreitern (Widget/Integration/Backend) + Coverage/CI + Analyzer-Warnings — durchgehend.

Schritt 0 zuerst: Plan nach **`docs/REFACTOR_PLAN.md`** speichern (Nutzer-Wunsch). Jede Stage = separate
Etappe/Commits, Tests jeweils mitgeschrieben. Umsetzung läuft **autonom durch** (Nutzer-Wunsch):
lokale Supabase + `flutter test` kontinuierlich als Gate; bei rot anhalten/fixen, nicht stumm überspringen.

## Verifikation

- **PQC (Stage 5):** Hybrid-Roundtrip-Test; **KAT-/Interop-Vektoren** stellen sicher, dass Nativ-FFI und
  Web-JS-Krypto **bit-identisch** ent-/verschlüsseln (committete `vectors.json`); Multi-Recipient + Tampering-Reject;
  manuell Nachricht senden→empfangen zwischen zwei Instanzen (eine nativ, eine web).
- **Wipe-Logik (1.2):** Unit-Test für `_checkAuthState` mit gemocktem Refresh-Fehler (Offline) → erwartet
  *kein* Wipe; echter Offline-Start mit bestehender Session behält Daten.
- **RLS (1.3) / Edge-Functions (1.4):** `supabase start`, Migration anwenden; mit zwei Test-Usern prüfen, dass
  Sender fremde Recipient-Zeilen *nicht* mehr liest; Edge-Function mit fremdem JWT → abgelehnt.
- **Event-Refactor (3):** zwei Instanzen, Chat wiederholt öffnen/schließen; per Logging/`removeChannel`-Zählung
  prüfen, dass am Ende nur noch **2 Channel-Typen** existieren (`user:<id>` + `chat:<id>:typing`) und beim
  Schließen sauber abgebaut wird (keine Akkumulation, keine Duplikat-Events). Reaktion/Profil-Änderung in
  Instanz A → kommt in B als Bus-Event an und aktualisiert die UI ohne separaten Channel. Re-Login → keine
  doppelten Handler.
- **Gesamt:** `flutter analyze` (0 Errors halten) + `flutter test` grün vor jeder Etappen-Abnahme.

---

## Anhang A — Event-Flow-Inventur (Ist-Zustand, authoritativ für Stage 3)

### A.1 Channels (6 Owner)
| Channel | Owner / Datei | Mechanismus | Lifecycle |
|---|---|---|---|
| `user:<userId>` | `event_bus_service.dart:31` | Broadcast (DB-Trigger) | sub `:54` / unsub `:60`; Provider `event_bus_provider.dart:20` |
| `chat:<chatId>:typing` | `typing_indicator_service.dart:133` | **Presence** | sub `:53` / unsub `:119`; **Provider nicht autoDispose** |
| `message_reactions:<messageId>` | `message_reactions_repository.dart:238` | PostgresChanges INSERT/DELETE | unsub `message_reactions_controller.dart:172` |
| `chat_reactions:<chatId>` | `message_reactions_repository.dart:310` | PostgresChanges (ungefiltert) | unsub `message_reactions_controller.dart:309`; **`keepAlive`-Leak `:58/:209`** |
| `table-db-changes` | `profiles_controller.dart:35` | PostgresChanges INSERT/UPDATE/DELETE | re-sub bei jedem Load `:26-83` (Race) |
| `realtime:<table>` | `realtime_subscription.dart:21` | PostgresChanges | generisch, quasi ungenutzt/auskommentiert |

### A.2 DB-Trigger-Emitter → `user:<id>`-Broadcast (`00003`/`00004`)
| EventType | Funktion | Trigger-Tabelle | Ziel-Channel |
|---|---|---|---|
| `newMessage` | `notify_members_new_message` `00003:50` | messages AFTER INSERT | `user:<recipient_id>` |
| `newChat` | `broadcast_new_chat_member` `00003:137` | chat_members AFTER INSERT | `user:<new_user_id>` |
| `membershipChanged` | `notify_membership_change` `00003:161` | chat_members INSERT/DELETE | `user:<member_id>` |
| `pendingMember` | `notify_admins_pending_member` `00003:231` | pending_chat_members INSERT | `user:<admin_id>` |
| `chatUpdate` | `notify_chat_update` `00003:322` | chats AFTER UPDATE | `user:<member_id>` |
| `chatDeleted` | `notify_chat_delete` `00003:375` + `…_on_member_removal` `00003:408` | chats BEFORE DELETE / chat_members DELETE | `user:<member_id>` |
| `messageUpdate` | `notify_message_update` `00003:437` | messages AFTER UPDATE | `user:<sender_id>` |
| `messageDelete` | `notify_message_delete` `00003:481` | messages BEFORE DELETE | `user:<member_id>` |

### A.3 Consumer (Bus-Ebene, alle via `eventBus.on`, kein `off`)
| EventType | Consumer | Downstream |
|---|---|---|
| `newMessage` | GlobalMessageHandler `:70` (decrypt→local→re-emit), MessagesController `:160` (UI), NotificationController `:32` | entschlüsseln, speichern, Metadaten, In-App-Notif |
| `newChat` | ChatsController `:120` (Key-Gen, fetch, state), NotificationController `:46` (→ synth. `memberStatusChanged`) | — |
| `chatUpdate` | ChatsController `:125` | `refreshChats` |
| `chatDeleted` | ChatsController `:130` | `markChatAsDeleted` (Stub!) + invalidate |
| `messageUpdate` | GlobalMessageHandler `:77` (Receipts), MessagesController `:169` (UI) | re-emit `processed` |
| `pendingMember` | ChatsController `:137`, NotificationController `:39` | invalidate `pendingMembersProvider` |
| `membershipChanged` | ChatsController `:144` | invalidate chatMembers/membershipStatus |
| `messageDelete` | **kein Consumer** | — |
| `memberStatusChanged` | nur lokal aus `newChat` synthetisiert | — |

### A.4 Non-Bus-Consumer (eigene Channels) → aggregiert in `chat_view_controller.dart:_setupListeners`
`typingIndicatorsProvider` (`:210`), `profilesControllerProvider` (`:224`), `chatReactionsProvider` (`:175`),
plus `chatProvider`/`isMemberProvider`/`isPendingMemberProvider`. Diese drei realtime-Quellen sind das
Ziel der Konsolidierung (→ Bus-Events bzw. Gateway-verwaltete Presence).

### A.5 Redundanzen/Mismatches (Refactor-Treiber)
- Doppelter In-Process-Layer: `on/off`-Map **+** `eventStream` — letzterer **ohne Consumer**.
- Re-Injection-Loop via `send(local:true)` → `_channel.trigger` (`global_message_handler.dart:175`,
  `event_bus_service.dart:113`).
- `off()` existiert, **0 Aufrufer** → Handler-Akkumulation bei Controller-Rebuild.
- `messageDelete` ohne Consumer; `memberStatusChanged` nur synthetisch.
