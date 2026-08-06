<!-- SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net> -->
<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->

# AGENTS.md

Guidance for AI coding agents (and humans) working in this repository. The
[README](README.md) covers what Chattr *is* and how to run it; this file covers
what you need to know before you change it.

Chattr is largely built by AI agents under human review, so the invariants below
are written to be read by one. Most of them exist because breaking them is
silent: the app keeps compiling, the tests keep passing, and a privacy property
is quietly gone.

## Commands

```bash
flutter pub get
flutter analyze                 # strict-casts / strict-inference / no raw types
flutter test
flutter test test/encryption_test.dart

# Code generation (*.freezed.dart, *.g.dart). --force-jit is required:
# sqlite3/webcrypto ship native build hooks, which break build_runner's
# default AOT compilation of the build script.
dart run build_runner build --delete-conflicting-outputs --force-jit

supabase start                  # local backend
```

Setup needs `.env` (copy `.env.example`): `SUPABASE_URL`,
`SUPABASE_ANDROID_URL` (the Android emulator reaches the host as `10.0.2.2`)
and `SUPABASE_ANON_KEY`. It is loaded at startup and bundled as a Flutter asset.

## The one architectural rule

**Realtime listeners never live in widgets.** Data flows one way:

```
Supabase Realtime → Repository → Riverpod Notifier/Controller → UI (watches state)
```

A widget that opens a `StreamBuilder` or calls Supabase directly is a bug, even
if it works. See `docs/ARCHITECTURE.md`.

### Layering (`lib/`)

- **`features/<feature>/`** — a `*_model.dart`, a `*_repository.dart` (data
  access) and a `*_controller.dart` (a Riverpod `StateNotifier`, usually
  `.autoDispose.family` keyed by `chatId`). Barrel files re-export a feature.
- **`core/`** — cross-cutting infrastructure: `security/`, `database/`,
  `events/`, `crypto/`, `notifications/`, `supabase/`, `config/`, `init/`.
- **`screens/`** — pure UI. `chat_view_screen.dart` is decomposed into
  `components/`, with logic in `features/chat_view/chat_view_controller.dart`.

### Two repositories per entity

Messages, chats and reactions each have a **remote** repository (Supabase) and a
**local** one (SQLite). Ciphertext comes off the server, is decrypted, and is
persisted locally. When you touch message or sync handling, keep both sides in
step — changing only one is the most common way to lose messages.

### One realtime channel

There is a single user channel (`user:<userId>`) in
`core/events/event_bus_service.dart`. Postgres triggers broadcast `BusEvent`s
onto it and controllers register typed handlers (`event_types.dart`). New
realtime behaviour hooks into that bus; do not open new channels.

## Invariants you must not break

**The server never sees plaintext.** Every message is encrypted client-side once
per recipient (one row per recipient). Fetching calls `mark_message_received()`,
which clears the ciphertext server-side. Read receipts are a *separate*,
suppressible signal — they are not what triggers deletion.

**The envelope is mirrored in three implementations.** The byte layouts in
`lib/core/crypto/message_context.dart` are mirrored in
`mcp_server/src/crypto_port.ts` and
`supabase/functions/insert-system-message/index.ts`. Change all three together,
and update the cross-implementation fixtures (`web_crypto/testdata/interop_*.json`).
A change to only one is undetectable until a real device fails to decrypt.

**Envelope v4** adds an identity signature and binds the ciphertext to
`chat_id‖sender_id‖message_id` via AAD, plus a hybrid-only scheme byte so there
is no silent post-quantum downgrade. **v5** wraps to a one-time prekey
(`lib/features/prekeys/`) for forward secrecy; the private half is deleted on
first decrypt — **only at consume-once decrypt sites, never on local re-decrypt**.
No prekey available means a fail-safe fall back to v4, never to something weaker.

**Push is an allowlist, not a denylist.** `notify_members_new_message` sends a
push only for `message_type = 'user'`. `system` and `summary` (the chat-summary
machinery in `lib/features/summary/`) travel as ordinary encrypted messages but
must never ring a phone. Realtime, by contrast, fires for *every* type — a
sleeping agent is woken by the message itself, so gating that too would break
the feature. A new message type is therefore silent by default; opt it into
push deliberately, and remember the server cannot tell machinery from
conversation because it cannot read either. Only the sender can say which it is.

**Migrations come in pairs.** A new table or column in `supabase/migrations/`
needs the matching local SQLite change in `core/database/database_schema.dart`.

**`SECURITY DEFINER` functions need their grants revoked.** PostgreSQL grants
EXECUTE to `PUBLIC` on every new function. A privileged function that does not
check `auth.uid()` itself must be revoked from `PUBLIC, anon, authenticated`
— and if you ever `DROP` and re-`CREATE` such a function, the revoke has to be
re-applied, because the drop took it with it.

**Never client-side scanning.** Chattr will not implement content scanning
(CSS / "Chat Control"), on-device or otherwise. If it is ever legally mandated,
the app goes offline instead. This is a product commitment, not a preference;
it is stated on the landing page and in the store listings, and those must stay
consistent.

## Conventions

- Files, DB columns and tables: `snake_case`. Classes/enums: `PascalCase`.
  Members: `camelCase`.
- Riverpod for state; `flutter_hooks` / `hooks_riverpod` in widgets.
- Generated files (`*.freezed.dart`, `*.g.dart`) and `test/**` are excluded from
  analysis. Never hand-edit generated files — rerun build_runner.
- Comments and docs are in **German and English**; both are expected. Match the
  surrounding file.
- `supabase/migrations/` is the active numbered schema. `migrations_backup/` is
  an older sequence — ignore it.

## The chatview fork

The chat UI uses an AI-maintained fork of `chatview` and `chatview_utils`
(branch `chattr` on top of upstream `3.1.0`) so package limitations are fixed at
the source instead of worked around. `pubspec.yaml` `dependency_overrides` pin a
git **tag** (`chattr-3.1.0-pN`); the lockfile records the resolved commit.

To iterate: point the override at a local `path:`, edit, hot-restart — then
commit the fork, push a new `chattr-3.1.0-pN` tag, and **flip the override back
to the tag before committing here**. A committed `path:` override breaks CI for
everyone else.

Every new patch must be recorded in **both** the fork's `FORK_NOTICE.md` **and**
its README patch table. They drifted apart once and the README fell five patches
behind.

## Flow diagrams

`docs/FLOW.md` holds the Mermaid sources of every app flow. They are mirrored
into `landing/assets/js/flow-sources.js`, which renders them on the landing page.
**Change a flow — encryption, notification triggers, receipt or clearing
behaviour, membership, blocking — and you update both places.**

## Testing expectations

Non-trivial changes come with tests, and the suite must be green before you call
something done. Beyond unit tests, prefer a check that exercises the real path:
several bugs here passed every test and still failed on a device, because the
test asserted the code it was testing rather than the behaviour.

Some tests need a live backend and fail without one — that is a known baseline,
not a regression you introduced. Check whether a failure is in that set before
you go chasing it.

## Platform notes

- **Web** uses `sqflite_common_ffi_web`; `web/sqflite_sw.js` and
  `web/sqlite3.wasm` are committed. Regenerate with
  `dart run sqflite_common_ffi_web:setup --force`.
- **Android** APKs are built `--split-per-abi`, which offsets the versionCode.
  It must increase monotonically or devices refuse the update with a misleading
  "You can't install this app" error.
- **Desktop** (macOS/Windows/Linux) builds but is not currently published.
- `super_clipboard` builds native Rust via cargokit — desktop and mobile builds
  need a Rust toolchain.

## Working on the live UI

To actually see and drive the running app rather than just run tests, follow
`docs/DESKTOP_E2E_TESTING.md`. Note that the message input is disabled in a
one-member group (you cannot message yourself), so the send/encrypt/realtime
path needs two participants — see `test/e2e_two_users_test.dart`.
