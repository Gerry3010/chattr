# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Chattr is an end-to-end encrypted chat app built with **Flutter** (Riverpod + hooks) and **Supabase**. Messages are hybrid-encrypted per recipient (X25519 + ML-KEM-768 KEM wrapping an AES-256-GCM key — post-quantum secure); the server stores ciphertext only and clears it as soon as the recipient's device has fetched (received) it — read status is a separate, suppressible signal, not what triggers deletion. Decrypted messages live only in a local encrypted SQLite database. Auth is anonymous (username-based, no email).

## Commands

```bash
flutter pub get                          # install dependencies
flutter run                              # run app (needs .env + a Supabase instance)
flutter analyze                          # static analysis (strict-casts/inference/raw-types enabled)
flutter test                             # run all tests
flutter test test/encryption_test.dart  # run a single test file

# Code generation (freezed / json_serializable — *.freezed.dart, *.g.dart)
# --force-jit is required: sqlite3/webcrypto ship native build hooks, which
# break build_runner's default AOT compilation of the build script.
dart run build_runner build --delete-conflicting-outputs --force-jit

# Local backend
supabase start                           # local Supabase stack

# Versioning / releases (see README.md for full flags)
./scripts/bump-version.sh --component app --type patch
./scripts/release.sh --component app --type patch --message "..."
```

Setup requires copying `.env.example` to `.env` and filling in `SUPABASE_URL`, `SUPABASE_ANDROID_URL` (Android emulator uses `10.0.2.2`), and `SUPABASE_ANON_KEY`. The `.env` file is loaded at startup and bundled as a Flutter asset.

## Architecture

The golden rule (`docs/ARCHITECTURE.md`): **realtime listeners never live in widgets.** Data flows one direction:

```
Supabase Realtime → Repository → Riverpod Notifier/Controller → UI (watches state only)
```

### Layering (`lib/`)
- **`features/<feature>/`** — feature-scoped logic. Each feature typically has a `*_model.dart`, a `*_repository.dart` (data access), and a `*_controller.dart` (a Riverpod `StateNotifier`, usually `.autoDispose.family` keyed by `chatId`). Barrel files (`auth.dart`, `chats.dart`, etc.) re-export a feature.
- **`core/`** — cross-cutting infrastructure: `security/` (encryption, key managers, biometrics), `database/` (SQLite), `events/` (the realtime event bus), `notifications/`, `crypto/`, `supabase/`, `config/`, `init/`. Re-exported via `core/core.dart`.
- **`screens/`** — pure UI. `screens/chat/` holds the chat UI; `chat_view_screen.dart` is decomposed into `components/` (app bar, banners, body, textfield) with logic extracted into `features/chat_view/chat_view_controller.dart`.

### Local + remote repository split
Messages, chats, and reactions each have **two** repositories — a remote one (`messages_repository.dart`, talks to Supabase) and a local one (`messages_local_repository.dart`, talks to SQLite). Controllers coordinate both: encrypted data comes off the server, gets decrypted, and is persisted/served locally. When changing message/sync handling, keep both sides in sync.

### Realtime via the Event Bus
Instead of many per-table Supabase subscriptions, there is **one** user-specific Realtime channel (`user:<userId>`) in `core/events/event_bus_service.dart`. Postgres triggers broadcast `BusEvent`s onto it; controllers register typed handlers (see `event_types.dart`). New realtime-driven behavior should hook into this bus, not open new channels.

### Startup
`main.dart` calls `AppInit.initialize()` (`core/init/app_init.dart`) before `runApp`. `AppInit` is a static holder that sets up dotenv, the SQLite factory (FFI on desktop, FFI-web on web), secure storage, encryption keys, biometrics, Supabase, and FCM **in order**. On startup it also decides whether to wipe local data: if an encryption key existed but no valid session is found, it calls `reinitialize()` which deletes the key, DB, and secure storage. The app is wrapped in `EasyLocalization` (de/en) then `ProviderScope`.

### Encryption flow (`core/security/`, see `docs/ENCRYPTION_INTEGRATION.md`)
Hybrid key pair (X25519 + ML-KEM-768) per chat; private keys stored encrypted in secure storage. Each message is encrypted separately for every recipient (one DB row per recipient). Fetching a message calls `mark_message_received()`, which clears the ciphertext from the server (delivery already wipes it); `mark_message_read()` then only records the read receipt for the sender and is **suppressed when the user disables read receipts** (reciprocal privacy setting, `sendReadReceiptsProvider`) — nothing lingers server-side either way. `MessageEncryptionService`, `ChatKeyPairManager`, and `EncryptionKeyManager` are the main entry points.

**Trust layer (audit 2026-07):** one long-term Ed25519 **identity key** per account (`IdentityKeyManager`) signs every per-chat KEM key (`KemKeyBinding`, `"s"` field) and every message (envelope **v4**: identity `sig` + AAD binding to `chat_id‖sender_id‖message_id` + hybrid-only scheme byte in `ek` — no silent PQ downgrade). Peers TOFU-pin identity keys, verify via QR v2 / safety numbers, and get warn-only badges/banners on changes (`lib/features/identity/`). Envelope/byte layouts (`lib/core/crypto/message_context.dart`) are mirrored in `mcp_server/src/crypto_port.ts` and `supabase/functions/insert-system-message/index.ts` — change all together (cross-impl fixtures `web_crypto/testdata/interop_v4.json`, `interop_v5.json`).

**Forward secrecy (audit P3, envelope v5):** the recipient KEM key was static, so a logged ciphertext + later device compromise decrypted everything. Fix = **one-time prekeys** (`lib/features/prekeys/`, `PrekeyManager`): each member publishes a pool of signed one-time hybrid KEM prekeys (server table `chat_member_prekeys`, public halves only; privates in local SQLite `kem_prekeys`). A sender **claims** one prekey per recipient (`claim_prekey` RPC, atomic) and wraps to it → **v5** (`{v:5, ek, pk, msg, sig}`, identical to v4 but the wrap targets the prekey named by `pk`). The recipient decrypts once and **deletes** the prekey's private half (the forward-secrecy act) — only at consume-once decrypt sites, never on local re-decrypt. No prekey/exhausted pool → fail-safe fallback to v4. `crypto.go`/`web_crypto` are unchanged (the KEM wire format doesn't move — only the envelope shape gains `pk`). Prekey privates sit in the cleartext DB until M4/SQLCipher (#119).

## Backend (`supabase/`)
- **`migrations/`** — the active, numbered schema (`00001_initial_schema.sql` … `0000N`). `migrations_backup/` is an older sequence; ignore it for new work.
- **`functions/`** — Edge Functions (`send-push-notification`, `insert-system-message`, `setup-env`).
- Tables: `profiles`, `chats`, `chat_members`, `pending_chat_members` (admin-approval queue), `messages` (encrypted, composite PK per recipient), `device_tokens` (FCM). All protected by RLS — recipients update message status only via dedicated DB functions, never direct content writes.
- When adding tables/functions, add a corresponding migration **and** the matching local SQLite schema change in `core/database/database_schema.dart`.

## Conventions
- Files and DB columns/tables: `snake_case`. Classes/enums: `PascalCase`. Members: `camelCase`.
- State management is Riverpod; widgets use `flutter_hooks` / `hooks_riverpod`. Watch controller providers in the UI — never call Supabase or open a `StreamBuilder` from a widget.
- Generated files (`*.freezed.dart`, `*.g.dart`) and `test/**` are excluded from analysis; never hand-edit generated files — rerun build_runner.
- Some code comments and docs are in German; both German and English are expected.

## chatview fork
The chat UI uses an **AI-agent-maintained fork** of `chatview` +
`chatview_utils` (`Gerry3010/chatview`, `Gerry3010/chatview_utils`, branch
`chattr` on top of upstream `3.1.0`) to fix package limits at the source instead
of hacking around them. `pubspec.yaml` `dependency_overrides` pin a **git tag**
(`chattr-3.1.0-pN`); the lockfile records the resolved commit for deterministic
CI. Each fork's `FORK_NOTICE.md` + README list every patch. Kept current weekly
by GitHub Actions on the forks (rebase onto new upstream) + `scripts/chatview-fork-sync.sh`
(local cron: tests chattr, opens a ref-bump PR); both notify via pipepush
(project `chattr-fork-sync`, pipeline `fork-rebase`).

**Applied patches (chattr consumes these):** 24h/local time (p1); getUserFromId
null-guard, updateMessage no-op + removeMessage (utils p1/p2); `sendOnEnter`
(p3); `onPaste` clipboard hook (p4); public **composer barrel**
`package:chatview/composer.dart` so we don't import `package:chatview/src/...`
(p5); `scrollViewKeyboardDismissBehavior` (p6); `ChatBubbleConfiguration.onLongPress`
clean callback (p7); slide-to-timestamp — opposite-swipe reveal + `onSwipeToTimestamp`
(p8); composer `contextMenuBuilder` (p9); reply-quote author + empty-message fixes
(p10); stable default message sort — id tiebreak (p11); **initials-circle avatar
fallback** — `userName` on `ProfileImageWidget`/`ProfileCircle`/`ChatViewAppBar` so a
picture-less user renders an initials circle instead of a 0px collapse, letting the app
show other-user avatars everywhere (p12); reply-quote `maxLines:2`+ellipsis cap and
`ChatBubble.emojiSize` for larger inline emoji runs (p13); `ChatViewAppBar.onTitleTap`
— tappable header title/avatar (opt-in) so the app opens a profile/contact sheet (p14);
`ChatBubble.shortMessageBorderRadius`/`longMessageBorderRadius` — override the base
corner radii while keeping message-grouping corner chaining, plus a reaction pill that
drops the empty avatar slot for a user who left (p15); reaction pill shows the p12
initials circle for a picture-less reactor incl. your own reaction (p16); starred-message
badge — `MessageConfiguration.isMessageStarred` predicate + frosted `starredIndicator`
overlay for every message type (p17); jump-to-message — `ChatView.highlightMessageNotifier`
jumps to any id (favorites/search) with an animated pulse, paging older messages in (p18);
robust jump — `hasClients` crash guard, bounded direction-flip viewport scan (no freeze on
variable-height media), `_scanGeneration` single-scan token, and one uniform `boxShadow`
glow in `MessageView` across all types incl. opaque media (p19).

**Iterating on the fork:** temporarily point the `chatview` override at
`path: ../chatview-fork`, edit + hot-restart, then commit the fork, push a new
`chattr-3.1.0-pN` tag, and flip the override back to that git ref before
committing chattr. **Every new `pN` MUST be recorded in BOTH the fork's
`FORK_NOTICE.md` AND its `README.md` patch table (and the applied-patches list
above) in the same go** — the README drifted to p14 while the tags reached p19
because only FORK_NOTICE was kept current. super_clipboard (composer paste) builds native Rust via
cargokit — desktop/mobile builds need a Rust toolchain (Codemagic installs it;
the Bitbucket **web** build does not).

**Deliberately NOT forked (closed after inspection — do not reopen as TODOs):**
these are legitimate uses of chatview's config/extension API, not hacks.
- **Theme-aware color defaults** — misguided for a package: the fork can't know
  the app's bubble colors; its hardcoded fallbacks suit the fork's own default
  bubbles and apps override per-theme (we do). Theme-deriving them is worse, no gain.
- **Configurable link preview** — `disableLinkPreview: true` is a legit config
  flag + `customMessageBuilder` (the intended extension point) renders our
  compact `LinkMessageBubble`. No hack to remove.
- **Native system-message type** — we still need `systemId` for action-gating +
  formatting, so a fork type wouldn't remove it, only move rendering at risk.
- **Explicit `isEdited`** — `updatedAt != null` drives the "edited" marker and we
  set `updatedAt` only from `editedAt`; explicit flag = core-model sugar, no gain.
- **Map-based reaction model** — a breaking core-model rewrite (chatview_utils +
  all rendering) for ~4 lines of app-side list flattening. Not worth it.

## Stance: never client-side scanning
Chattr will **never** implement client-side scanning (CSS / "Chat Control"). If
it is ever legally mandated, the app goes offline rather than scan a message.
This pledge is a **product commitment** and must be carried consistently across
listings: it lives on the landing page (`index.html`, `#pledge` section) and
**must be included in the App Store and TestFlight descriptions** for every
release. Keep the wording in sync across all three.

## Flow diagram convention
`docs/FLOW.md` holds the Mermaid sources of ALL app flows (account/profile,
chats, messaging incl. key exchange, media, group join, push, message actions,
blocking). They are mirrored into `landing/assets/js/flow-sources.js`, which
renders them on the landing page (`index.html` accordion section `#technik`
and the expanded `technik.html`) via the vendored
`landing/assets/js/mermaid.min.js`. **When changing any of these flows
(encryption, notify triggers, receipt/clearing behavior, membership,
blocking), update BOTH places.** Pushing `landing/**` changes to main
auto-deploys chattr.geraldhofbauer.net via the pipeline.

## Platform notes
- **Web** uses `sqflite_common_ffi_web`; `web/sqflite_sw.js` and `web/sqlite3.wasm` are committed. Regenerate with `dart run sqflite_common_ffi_web:setup --force` if missing.
- CI is **Bitbucket Pipelines** (`bitbucket-pipelines.yml`): builds Flutter web from `version.json`, writes `.env` from pipeline secrets, deploys to a VPS.

## Homepage APK download (`scripts/deploy-apk-homepage.sh`)
The Android APK at `geraldhofbauer.net/files/chattr-android` is published separately from the app
stores. Two hard rules — both have broken real installs:
- **versionCode MUST increase monotonically.** Build with
  `flutter build apk --release --split-per-abi --target-platform android-arm64 --build-number=<previous+1>`
  → `app-arm64-v8a-release.apk`, whose versionCode is `build-number + 2000` (the arm64 ABI offset that
  `--split-per-abi` adds). **NEVER** deploy the plain `--target-platform` (no-split) `app-release.apk`
  for this channel: it drops the versionCode to the raw `build-number` (e.g. `23`), which is *lower*
  than the previous `20xx` → Android refuses the downgrade with **"You can't install this app on your
  device"**. Always verify the **served** file afterwards: download it and confirm
  `aapt2 dump badging` shows the expected `versionCode='20xx'` (not a 2-digit number).
- **Sign with the established upload key** (`android/upload-keystore.jks`, alias `upload`) and verify
  its cert fingerprint before every deploy — a different key breaks updates for existing installs.

The deploy script auto-relinks the new asset to the Craft download entry, but its **title +
description are hand-curated** — update them to the new version each release (the script does not).

**Target state (with the `chattr.at` cutover, see `docs/CHATTR_AT_CUTOVER.md`):** the Android APK's
**distribution** is delivered automatically over **`chattr.at`** as part of the deployment (no
separate manual homepage publish). The APK is **not** auto-built — it is built manually (see
`docs/BUILDING.md`); only its distribution is automated. **Implementing that APK auto-deploy
pipeline is the Lead-Dev's job** — do not build it as a side task. Until then, the manual
`scripts/deploy-apk-homepage.sh` flow above (and its two hard rules) stays authoritative.

## Manual desktop testing (driving the live UI)
To actually *see*/click the running app (not just `flutter test`), follow **`docs/DESKTOP_E2E_TESTING.md`**. Key gotchas on this GNOME/Wayland machine:
- Screenshots of a native-Wayland window are blocked. Launch the built bundle binary with `GDK_BACKEND=x11` so it runs under **XWayland**, then capture with `import -window <id>` (window id via `xdotool search --name '^chattr$'`) and drive input with `xdotool`. `flutter run` does **not** pass `GDK_BACKEND` to the app.
- `Failed to register FCM token / FCM token is null` on desktop is **expected** (no Firebase on Linux), not a bug.
- The message input is **disabled in a 1-member group** (can't message yourself); the send/encrypt/realtime path needs two participants — see `test/e2e_two_users_test.dart`. 1:1 chats require scanning another user's QR code (second device/camera), so they're not solo-drivable on desktop.
- Known i18n gap: the empty-chat state shows "No message" / "Reload" in English.
