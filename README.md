# Chattr

A post-quantum end-to-end encrypted chat application built with Flutter and Supabase.

## Features

### Security & Privacy
- 🔐 **End-to-end encryption** — post-quantum hybrid (X25519 + ML-KEM-768 KEM wrapping AES-256-GCM), encrypted separately for every recipient
- 🪪 **Identity keys & trust verification** — one long-term Ed25519 identity key per account signs every per-chat key and every message; peers TOFU-pin identity keys and verify them via QR codes / safety numbers, with warn-only badges on key changes
- ⏩ **Forward secrecy** — one-time signed prekeys (message envelope v5), so a logged ciphertext plus a later device compromise no longer decrypts past messages
- 🔑 **Anonymous authentication** — username-based login, no email required
- 🗑️ **Content-blind server** — ciphertext is cleared from the server as soon as the recipient's device fetches it (delivery, not read status); nothing lingers server-side
- 🔒 **Local encrypted storage** — decrypted messages live only in a local on-device SQLite database
- 🙈 **Reciprocal read-receipt privacy** — turning off your read receipts also suppresses the ones you send
- 👤 **Admin approval system** — pending-membership queue for chat access control
- 🚫 **Never client-side scanning** — a standing product pledge; Chattr would go offline before scanning a message

### Chat Features
- 💬 **Real-time messaging** over a single user-scoped Supabase Realtime channel
- 📱 **Group chats and 1:1 conversations** with multiple admins and member management
- 🖼️ **Encrypted media** — photos, video, audio and files, each end-to-end encrypted; captions, multi-image albums, pre-send editing (crop/trim), and chunked transfer for large files
- 😀 **Reactions** — emoji reactions per message
- ✏️ **Message editing, replies/quotes, starred favorites, and jump-to-message**
- 🔗 **Link previews & inline link videos** — YouTube and Reddit/stream links play inline in the bubble, minimise to a floating in-app picture-in-picture window, and dock back
- 🅰️ **Group mentions** — @all / @admins / @members with typeahead and unread-mention markers
- 📝 **Markdown formatting** — a safe Markdown subset in messages
- ✓ **Read receipts** (suppressible) and 🗨️ **system messages** for membership changes
- 🚫 **Blocking** and 📤 **message deletion** (senders can delete unread messages)

### User Experience
- 📱 **QR code sharing & scanning** for contact/chat joining
- 🔔 **Push notifications** for new messages, mentions, and membership requests
- 🪟 **Floating in-app video** (picture-in-picture) that follows you across chats
- ⬇️ **In-app Android auto-update** — new APKs are published to and served from chattr.at; the app checks for and installs updates itself
- 🍏 **iOS share-sheet suggestions** — recent Chattr conversations surface in the system share sheet (opt-in; no message content is shared)
- 🌍 **Multi-language support** (German/English)
- 🔄 **Offline support** with local storage and sync; unread counts and last-message metadata

## Setup

### Prerequisites

- Flutter SDK (^3.10.4)
- Supabase (local or cloud instance)

### Installation

1. Clone the repository
2. Copy `.env.example` to `.env`:
   ```bash
   cp .env.example .env
   ```
3. Edit `.env` and add your Supabase credentials:
   ```
   SUPABASE_URL=http://127.0.0.1:54321
   SUPABASE_ANDROID_URL=http://10.0.2.2:54321
   SUPABASE_ANON_KEY=your_anon_key_here
   ```
4. Install dependencies:
   ```bash
   flutter pub get
   ```
5. Run the app:
   ```bash
   flutter run
   ```

### Supabase Setup

For local development with Supabase:

```bash
supabase start
```

See `docs/QUICKSTART.md` for detailed database schema and setup instructions.

## Architecture

### Flutter App Structure
```
lib/
├── screens/          # UI layer (chat list, chat view, settings, etc.)
├── features/         # Business logic organized by feature:
│   ├── auth/        # Authentication (login, user management)
│   ├── chats/       # Chat management (create, join, leave)
│   ├── messages/    # Message handling (send, receive, encrypt/decrypt)
│   ├── members/     # Membership management (approve, reject)
│   ├── identity/    # Long-term identity keys, TOFU pinning, verification
│   ├── prekeys/     # One-time prekeys (forward secrecy)
│   ├── media/       # Encrypted media, inline video, picture-in-picture
│   ├── mentions/    # @-mentions in group chats
│   └── profiles/    # User profile management
└── core/            # Shared infrastructure:
    ├── config/      # App configuration
    ├── database/    # Local SQLite database
    ├── events/      # The single-channel realtime event bus
    ├── security/    # Encryption services (hybrid KEM, identity keys, local storage)
    ├── crypto/      # Envelope / message-context byte layouts
    └── notifications/ # Push notifications (FCM)
```

### Database Structure

The active schema is a numbered migration sequence under `supabase/migrations/`
(`00001_initial_schema.sql` … `000NN`). Each schema change is paired with the
matching local SQLite change in `core/database/database_schema.dart`.

**Key tables:**
- `profiles` — user profiles (username)
- `chats` / `chat_members` / `pending_chat_members` — rooms, approved members, and the admin-approval queue
- `messages` — encrypted messages, one row per recipient
- `chat_member_prekeys` — public one-time prekeys for forward secrecy (private halves stay on-device)
- `device_tokens` — FCM tokens for push notifications
- plus media-retention, reporting/moderation, and admin tables added by later migrations

## Encryption & Security

### End-to-End Encryption
- **Hybrid key pairs (X25519 + ML-KEM-768)** generated per chat
- Private keys stored encrypted in local device storage
- Each message encrypted separately for each recipient
- Server never has access to decrypted content

### Message Lifecycle
1. **Send**: encrypted separately for each recipient, wrapped to a one-time prekey (envelope v5) and signed by the sender's identity key
2. **Deliver**: the recipient's device fetches and decrypts; `mark_message_received()` clears the ciphertext from the server
3. **Read**: `mark_message_read()` records a read receipt for the sender only — suppressed when the user disables read receipts
4. **Storage**: only decrypted messages are kept, locally, in SQLite

### Row Level Security (RLS)
- All tables protected with comprehensive RLS policies
- Users can only access their own data and chats they're members of
- Admins have additional permissions for their chats
- Recipients use dedicated DB functions to update message status (can't modify content)

## Platform Support

### Web: Local Encrypted Storage
This app uses `sqflite_common_ffi_web` to provide a local encrypted SQLite database on web builds.

- Required assets are committed to the repo: `web/sqflite_sw.js` and `web/sqlite3.wasm`.
- If these files ever go missing, regenerate them with:
  - `dart run sqflite_common_ffi_web:setup --force`
- When hosting a release build, ensure both files are served from the site root (the `web/` folder in this project).
- No additional manual registration is needed in most cases; the service worker is handled by the package at runtime.

## Versioning & Releases

This project uses [Semantic Versioning](https://semver.org/lang/de/) for all components (Client, Backend, Landing Page).

### Version Management

All versions are centrally managed in `version.json`:
```json
{
  "app_version": "1.10.0",
  "build_number": 30,
  "backend_version": "1.4.0",
  "min_backend_version": "1.0.0",
  "min_client_version": "1.0.0",
  "landing_version": "1.2.0",
  "changelog_url": "https://bitbucket.org/Gerry3010/chattr/src/main/CHANGELOG.md"
}
```

### Bump Version

Use the bump script to increase version numbers:

```bash
# Bump app version (patch)
./scripts/bump-version.sh --component app --type patch

# Bump backend version (minor)
./scripts/bump-version.sh --component backend --type minor

# Bump all components (major)
./scripts/bump-version.sh --component all --type major
```

**Version Types:**
- `major`: Breaking changes (1.0.0 → 2.0.0)
- `minor`: New features (1.0.0 → 1.1.0)
- `patch`: Bug fixes (1.0.0 → 1.0.1)

### Create a Release

```bash
# Create release with version bump
./scripts/release.sh --component app --type patch --message "Bug fixes and improvements"

# Create release without version bump (if already bumped)
./scripts/release.sh --component app --message "Release notes"

# Dry run to see what would happen
./scripts/release.sh --component all --type minor --dry-run
```

The release script will:
1. Bump version (if `--type` is provided)
2. Update CHANGELOG.md
3. Create a git commit
4. Create a git tag (e.g., `v1.0.0`, `backend-v1.0.0`)

**Push the release:**
```bash
git push origin main
git push origin <tag-name>
```

### Version Compatibility

The app automatically checks backend compatibility on startup:
- Client compares backend version with `min_backend_version`
- If incompatible, user is shown an update dialog
- Version info is available in Settings screen

### CI/CD Integration

Bitbucket Pipelines automatically:
1. Reads version from `version.json`
2. Builds with correct version numbers
3. Deploys with version logging
4. Tracks versions in Supabase `app_versions` table

### Changelog

All changes are documented in `CHANGELOG.md` following [Keep a Changelog](https://keepachangelog.com/) format.

## Roadmap

Chattr runs on a post-quantum (X25519 + ML-KEM-768) end-to-end encrypted base.
It is distributed as a self-updating direct-download Android APK (served from
chattr.at) and via TestFlight on iOS. Remaining work:

**Planned**
- [ ] **Final acceptance pass** — a full feature-by-feature run-through as the last verification step before a wider release.
- [ ] **iOS / macOS native crypto** — build the PQC `xcframework` (requires an Apple host); web, Linux, and Android are already bundled.
- [ ] **Desktop distribution** — Flutter desktop builds exist but aren't published yet; the download links are already config-driven.
- [ ] **App lock / privacy screen** — blur-on-background, clear the in-memory encryption key, biometric re-unlock.
- [ ] **Local database encryption (SQLCipher)** — encrypt the on-device SQLite store at rest.
- [ ] **Delete messages locally (delete-for-me)** — remove a message from this device's store/view; today a received message can't be cleared at all. (Unsend/delete-for-everyone is a separate, larger step.)

**Nice to have**
- [ ] Chat info / description page.
- [ ] Screenshot protection.
- [ ] General chat key rotation (beyond the per-recipient forward secrecy that member removal already provides).
- [ ] Multi-device support and backup/restore.
- [ ] UI animations & transitions polish.

**Intentionally deferred**
- Model code generation: a few models (`Message`, the event-type hierarchy) are hand-written on purpose (super-parameters across inheritance, polymorphism, `Optional`-based `copyWith`, mutable transient fields) — freezed/json_serializable can't express these cleanly. Migrating *all* models is a possible dedicated refactor, not a quick change.

See `docs/REFACTOR_PLAN.md` for the full triage/remediation history.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

**Building from source:** this repo ships no build automation — see
[docs/BUILDING.md](docs/BUILDING.md) to build the app yourself for any platform
(you supply your own backend + Firebase project). The public GitHub mirror runs
**security scans only** (CodeQL, Semgrep, Trivy, govulncheck, Dependabot) plus a
Claude-driven security review on pull requests; primary CI stays on Bitbucket.

## Security

Found a vulnerability? Please report it privately — see [SECURITY.md](SECURITY.md).
That file also documents the security invariants Chattr holds itself to
(content-blind server, no backdoor, never client-side scanning, envelope
integrity, RLS, env-only secrets).

## License

Chattr is free software licensed under the **GNU Affero General Public License
v3.0 or later** (AGPL-3.0-or-later) — see [LICENSE](LICENSE). The network
copyleft clause is deliberate: anyone running a modified Chattr server must make
their source available, so a privacy app can't be quietly forked into a
closed, untrustworthy one.
