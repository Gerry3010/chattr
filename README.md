# Chattr

End-to-end encrypted chat application built with Flutter and Supabase.

## Features

### Security & Privacy
- 🔐 **End-to-end encryption** using a post-quantum hybrid (X25519 + ML-KEM-768, AES-256-GCM) for all messages
- 🔑 **Anonymous authentication** with username-based login (no email required)
- 🗑️ **Automatic content cleanup** - encrypted messages are deleted from server after reading
- 🔒 **Local encrypted storage** - messages stored in encrypted SQLite database
- 👤 **Admin approval system** - pending membership requests for chat access control

### Chat Features
- 💬 **Real-time messaging** with Supabase Realtime
- 📱 **Group chats and 1:1 conversations**
- 👥 **Multiple admins per chat** with member management
- ✓ **Read receipts** - track message delivery and read status
- 🗨️ **System messages** for membership changes (joined/left)
- 📤 **Message deletion** - senders can delete unread messages

### User Experience
- 📱 **QR code sharing** for easy contact/chat joining
- 🌍 **Multi-language support** (German/English)
- 🔔 **Push notifications** for new messages and membership requests
- 🔄 **Offline support** with local message storage and sync
- 📊 **Chat metadata** - unread counts, last message timestamps

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
│   └── profiles/    # User profile management
└── core/            # Shared infrastructure:
    ├── config/      # App configuration
    ├── database/    # Local SQLite database
    ├── security/    # Encryption services (hybrid KEM, local storage)
    └── logging/     # Logging service
```

### Database Structure
```
supabase/migrations/
├── 00001_initial_schema.sql       # Tables, indexes, constraints
├── 00002_functions.sql            # Core DB functions
├── 00003_event_functions.sql      # Realtime event handlers
├── 00004_triggers.sql             # Database triggers
└── 00005_row_level_security.sql   # RLS policies
```

**Key Tables:**
- `profiles` - User profiles (username)
- `chats` - Chat rooms with admin management
- `chat_members` - Approved chat members
- `pending_chat_members` - Pending membership requests
- `messages` - Encrypted messages (one row per recipient)
- `device_tokens` - FCM tokens for push notifications

## Encryption & Security

### End-to-End Encryption
- **Hybrid key pairs (X25519 + ML-KEM-768)** generated per chat
- Private keys stored encrypted in local device storage
- Each message encrypted separately for each recipient
- Server never has access to decrypted content

### Message Lifecycle
1. **Send**: Message encrypted with recipient's public key
2. **Receive**: Message fetched and decrypted with private key
3. **Read**: `mark_message_read()` DB function clears encrypted content from server
4. **Storage**: Only decrypted messages stored locally in encrypted SQLite

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
  "app_version": "1.0.0",
  "build_number": 1,
  "backend_version": "1.0.0",
  "min_backend_version": "1.0.0",
  "min_client_version": "1.0.0",
  "landing_version": "1.0.0"
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

Chattr runs on a post-quantum (X25519 + ML-KEM-768) end-to-end encrypted base
and is live on Google Play internal testing. Remaining work:

**Planned**
- [ ] **Push notifications** — finish the FCM end-to-end flow (delivery, deep-linking, token lifecycle); currently incomplete.
- [ ] **Final acceptance pass** — a full feature-by-feature run-through as the last verification step before a wider release.
- [ ] **iOS / macOS native crypto** — build the PQC `xcframework` (requires an Apple host); web, Linux, and Android are already bundled.
- [ ] **Single active video player** — pause other inline videos when one starts playing.

**Nice to have**
- [ ] QR scanner to add members (the share-invite side is done).
- [ ] Chat info / description page.
- [ ] Screenshot protection.
- [ ] General chat key rotation (beyond the per-recipient forward secrecy that member removal already provides).
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
