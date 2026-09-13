<!--
SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Building Chattr from source

Chattr is an end-to-end encrypted Flutter + Supabase chat app. **This repository
ships no build automation** — there is no CI that produces app binaries here, and
the public mirror runs security scans only. If you want an Android, iOS, Linux,
macOS, Windows, or web build, **you build it yourself** with the steps below.

> You supply your own backend and your own Firebase project. The repo does not
> contain any project's live configuration — see [Firebase configuration](#firebase-configuration-push-notifications).

## Prerequisites

- **Flutter SDK** with Dart `>=3.12.0 <4.0.0` (a recent stable channel).
  Verify with `flutter --version` and `flutter doctor`.
- **A Rust toolchain** (`rustup`, stable) — `super_clipboard` builds a native
  component via cargokit on desktop/mobile. `flutter doctor` won't flag this;
  install `rustup` before a desktop/mobile build.
- **A Go toolchain** — the post-quantum crypto library is built from Go sources
  (see below). Not needed for a web-only build.
- Platform toolchains for your target:
  - **Android:** Android SDK + NDK (Android Studio), JDK 17.
  - **iOS/macOS:** Xcode + CocoaPods (Apple host only).
  - **Linux:** `clang cmake ninja-build pkg-config libgtk-3-dev` + `mpv`/`libmpv`
    (inline video via media_kit).
  - **Windows:** Visual Studio with the "Desktop development with C++" workload.
- A **Supabase** instance (hosted or self-hosted — see `supabase/` and
  `docs/`). You need its URL and anon key.

The post-quantum crypto core exists in two implementations. Only the **web**
bundle is committed (`web/chattr_crypto.js`) — the **native** library
(`native/chattr_crypto`, Go) is a generated artifact and is **not** in the
repository. Build it before your first native run, or the app compiles fine and
then fails at runtime with a missing `libchattr_crypto`:

```bash
./native/build.sh                                        # host desktop (Linux/macOS/Windows)
ANDROID_NDK_HOME=/path/to/ndk ./native/build.sh android  # all Android ABIs
./native/build.sh apple                                  # iOS + macOS xcframework (Apple host)
```

Requires a **Go toolchain**, plus the Android NDK / Xcode for those targets. See
`native/README.md` for the output paths and how each platform picks the library up.

## 1. Get the code and dependencies

```bash
git clone <this-repo> chattr && cd chattr
flutter pub get
```

## 2. Configure the backend (`.env`)

```bash
cp .env.example .env
```

Fill in:

- `SUPABASE_URL` — your Supabase project URL.
- `SUPABASE_ANDROID_URL` — same, but reachable from the Android emulator
  (use `http://10.0.2.2:<port>` for a local stack).
- `SUPABASE_ANON_KEY` — your project's anon key.

`.env` is loaded at startup and bundled as a Flutter asset. It is **gitignored** —
never commit it.

## 3. Firebase configuration (push notifications)

Push notifications use Firebase Cloud Messaging. **The repo does not ship any
Firebase config** — you drop in your own project's *client* config (these are
public client identifiers, not secrets, but they identify a specific Firebase
project, so each builder supplies their own). Create a Firebase project, add
apps for the platforms you build, and place the config here:

| Platform | File | Where to get it |
|---|---|---|
| **Web** | `web/index.html` (`firebaseConfig` object, ~line 103) **and** `web/firebase-messaging-sw.js` **and** `lib/features/push_notifications/fcm_service.dart` (`FirebaseOptions`) | Firebase console → Project settings → your **Web app** config |
| **Android** | `android/app/google-services.json` | Firebase console → your **Android app** → download `google-services.json` |
| **iOS/macOS** | `ios/Runner/GoogleService-Info.plist` (and `macos/Runner/` if targeting macOS) | Firebase console → your **Apple app** → download `GoogleService-Info.plist` |

The three web spots must all carry the **same** `apiKey` / `messagingSenderId` /
`appId` / `projectId`.

**Building without push?** You can run the app without a Firebase project — FCM
registration will just fail (harmless; on Linux desktop it fails by design).
For a clean no-push build, supply placeholder values or a throwaway Firebase
project; message send/receive and encryption do not depend on FCM.

*Server side:* the FCM **service-account private key** (a real secret) lives in
your Supabase Edge Function secret `FCM_SERVICE_ACCOUNT`, never in the app or
this repo. See `docs/FCM_SETUP.md`.

## 4. Code generation

Some `*.freezed.dart` / `*.g.dart` files are generated. `--force-jit` is required
(sqlite3/webcrypto ship native build hooks that break AOT compilation of the
build script):

```bash
dart run build_runner build --delete-conflicting-outputs --force-jit
```

## 5. Build

| Target | Command |
|---|---|
| **Web** | `flutter build web --release` (see the web note below) |
| **Android APK** (arm64) | `flutter build apk --release --target-platform android-arm64` |
| **Android App Bundle** | `flutter build appbundle --release` |
| **iOS** (Apple host) | `flutter build ipa --release` |
| **Linux** | `flutter build linux --release` |
| **macOS** (Apple host) | `flutter build macos --release` |
| **Windows** | `flutter build windows --release` |

**Web note:** the web build is self-contained — static assets plus the public
Firebase web config you filled in above. Nothing secret is injected; just make
sure the three web config spots (step 3) point at your Firebase project.
`web/sqflite_sw.js` and `web/sqlite3.wasm` are committed; regenerate with
`dart run sqflite_common_ffi_web:setup --force` if missing.

**Android release signing:** provide your own keystore
(`android/key.properties` + a `.jks`) — no signing key is included.

## Run in development

```bash
flutter run          # needs a configured .env + a reachable Supabase instance
flutter test         # unit/widget tests
flutter analyze      # static analysis
```

For self-hosting the backend end-to-end, start from `supabase/` (migrations +
Edge Functions) and `docs/`. A provider-agnostic self-hosting guide is planned
(see `docs/CHATTR_AT_CUTOVER.md` for the domain/deploy direction).
