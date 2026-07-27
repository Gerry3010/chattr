# Native hybrid-KEM crypto library

`chattr_crypto` is a small Go c-shared library implementing the hybrid
**X25519 + ML-KEM-768** KEM-DEM used for end-to-end message encryption. It is the
native (dart:ffi) counterpart of the web bundle in `../web_crypto/`; both produce
a byte-identical wire format (HKDF info `chattr-hybrid-kem-v1`).

The compiled libraries are **generated artifacts** and are gitignored — build them
before building/running the app for a native platform.

## Build

```bash
# Host (Linux/macOS/Windows desktop) -> native/chattr_crypto/build/libchattr_crypto.{so,dylib,dll}
./native/build.sh

# Android (all ABIs) -> android/app/src/main/jniLibs/<abi>/libchattr_crypto.so
ANDROID_NDK_HOME=/path/to/ndk ./native/build.sh android

# Apple (iOS device+sim & macOS) -> native/build/apple/chattr_crypto.xcframework
./native/build.sh apple
```

- **Linux/desktop:** `linux/CMakeLists.txt` bundles the host `.so` into the app
  bundle's `lib/` dir automatically (warns if missing).
- **Android:** Flutter bundles `jniLibs/<abi>/*.so` into the APK automatically.
- **Web:** not FFI — see `../web_crypto/` (`npm run build` → `web/chattr_crypto.js`).
- **iOS/macOS:** `./native/build.sh apple` produces `chattr_crypto.xcframework`
  (iOS device arm64, iOS simulator arm64/x86_64, macOS arm64/x86_64). The local
  `ios/chattr_crypto.podspec` and `macos/chattr_crypto.podspec` `-force_load` the
  matching static slice into the Runner target, so the exported `pb_*` symbols
  stay in the app binary and the Dart side resolves them via
  `DynamicLibrary.process()`. Rebuild after changing the Go sources, then run
  `pod install` in `ios/`/`macos/` (or just `flutter run`).

## Test

```bash
cd native/chattr_crypto && go test ./...     # roundtrip, tamper, fallback, wrong-key
flutter test test/pqc_ffi_test.dart          # Dart FFI roundtrip (uses the built .so)
```
