#!/usr/bin/env bash
# Copyright (C) 2026 Gerald Hofbauer <info@geraldhofbauer.net>
# AGPLv3 — see <https://www.gnu.org/licenses/>.
#
# Builds the Chattr hybrid-KEM c-shared library (X25519 + ML-KEM-768) for the
# host platform, and — when the Android NDK is present — for every Android ABI.
# Wire format is identical to the web/JS implementation.
#
# Usage:
#   ./build.sh            # host platform (Linux/macOS/Windows desktop)
#   ./build.sh android    # all Android ABIs (needs ANDROID_NDK_HOME)
#   ./build.sh apple      # iOS device+sim & macOS -> chattr_crypto.xcframework (needs Xcode)
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/chattr_crypto" && pwd)"
cd "$DIR"
NAME="chattr_crypto"

build_host() {
  mkdir -p build
  local ext
  case "$(uname -s)" in
    Linux)  ext="so" ;;
    Darwin) ext="dylib" ;;
    MINGW*|MSYS*|CYGWIN*) ext="dll" ;;
    *) echo "unsupported host"; exit 1 ;;
  esac
  local out="build/lib${NAME}.${ext}"
  echo "→ $out"
  CGO_ENABLED=1 go build -buildmode=c-shared -o "$out" .
}

build_android() {
  : "${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME to the NDK path}"
  # The NDK ships exactly one prebuilt toolchain, named after the *build* host.
  # Don't assume Linux: Git Bash on Windows needs windows-x86_64, macOS
  # darwin-x86_64 (also on Apple Silicon — the NDK has no arm64 host build).
  local tcroot="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt" host tc=""
  case "$(uname -s)" in
    Linux)                host=linux-x86_64 ;;
    Darwin)               host=darwin-x86_64 ;;
    MINGW*|MSYS*|CYGWIN*) host=windows-x86_64 ;;
    *)                    host="" ;;
  esac
  [ -n "$host" ] && [ -d "$tcroot/$host/bin" ] && tc="$tcroot/$host/bin"
  # Unknown/renamed host dir — fall back to whatever the NDK actually ships.
  [ -n "$tc" ] || tc="$(ls -d "$tcroot"/*/bin 2>/dev/null | head -1)"
  [ -n "$tc" ] && [ -d "$tc" ] || {
    echo "no NDK toolchain under $tcroot — is ANDROID_NDK_HOME correct?" >&2; exit 1; }

  declare -A abis=(
    [arm64-v8a]="aarch64-linux-android21-clang"
    [armeabi-v7a]="armv7a-linux-androideabi21-clang"
    [x86_64]="x86_64-linux-android21-clang"
  )
  for abi in "${!abis[@]}"; do
    local dest="../../android/app/src/main/jniLibs/$abi"
    mkdir -p "$dest"
    # On Windows the NDK exposes the wrappers as .cmd batch files.
    local cc="$tc/${abis[$abi]}"
    [ -f "$cc" ] || cc="$cc.cmd"
    [ -f "$cc" ] || { echo "compiler not found: $tc/${abis[$abi]}" >&2; exit 1; }
    echo "→ $dest/lib${NAME}.so"
    # 16 KB page alignment: Google Play requires all native .so to be aligned to
    # a 16 KB max-page-size from Nov 2025. NDK r28's clang defaults to this, but
    # pass the linker flag explicitly so the lib is aligned regardless of which
    # NDK the CI happens to use (r27 does NOT default to it). Harmless on r28.
    CGO_ENABLED=1 CC="$cc" \
      GOOS=android GOARCH="$([[ $abi == arm64-v8a ]] && echo arm64 || { [[ $abi == x86_64 ]] && echo amd64 || echo arm; })" \
      go build -buildmode=c-shared \
        -ldflags="-extldflags=-Wl,-z,max-page-size=16384,-z,common-page-size=16384" \
        -o "$dest/lib${NAME}.so" .
  done
}

# Builds a static c-archive (.a + header) for every Apple slice and bundles them
# into chattr_crypto.xcframework. The Dart side links this statically and looks
# the symbols up via DynamicLibrary.process() (see lib/core/crypto/ml_kem_ffi.dart).
build_apple() {
  command -v xcrun >/dev/null 2>&1 || { echo "xcrun not found — Xcode required"; exit 1; }
  local OUT="$DIR/../build/apple"
  local IOS_MIN=13.0 MAC_MIN=10.15
  rm -rf "$OUT"
  mkdir -p "$OUT"

  # $1 GOOS  $2 GOARCH  $3 clang-target-triple  $4 sdk  $5 output .a path
  _slice() {
    local sysroot clang archf
    sysroot="$(xcrun --sdk "$4" --show-sdk-path)"
    clang="$(xcrun --sdk "$4" --find clang)"
    case "$2" in arm64) archf=arm64 ;; amd64) archf=x86_64 ;; esac
    echo "→ ${5#$OUT/}  ($1/$2  $3)"
    mkdir -p "$(dirname "$5")"
    CGO_ENABLED=1 GOOS="$1" GOARCH="$2" \
      CC="$clang -target $3 -isysroot $sysroot" \
      CGO_CFLAGS="-target $3 -isysroot $sysroot" \
      CGO_LDFLAGS="-target $3 -isysroot $sysroot" \
      go build -buildmode=c-archive -trimpath -o "$5" .
  }

  # iOS device (arm64)
  _slice ios    arm64 "arm64-apple-ios${IOS_MIN}"             iphoneos        "$OUT/ios-arm64/lib${NAME}.a"
  # iOS simulator (arm64 + x86_64 -> fat)
  _slice ios    arm64 "arm64-apple-ios${IOS_MIN}-simulator"   iphonesimulator "$OUT/ios-sim-arm64/lib${NAME}.a"
  _slice ios    amd64 "x86_64-apple-ios${IOS_MIN}-simulator"  iphonesimulator "$OUT/ios-sim-amd64/lib${NAME}.a"
  mkdir -p "$OUT/ios-sim"
  lipo -create "$OUT/ios-sim-arm64/lib${NAME}.a" "$OUT/ios-sim-amd64/lib${NAME}.a" -output "$OUT/ios-sim/lib${NAME}.a"
  cp "$OUT/ios-sim-arm64/lib${NAME}.h" "$OUT/ios-sim/lib${NAME}.h"
  # macOS (arm64 + x86_64 -> fat)
  _slice darwin arm64 "arm64-apple-macos${MAC_MIN}"  macosx "$OUT/macos-arm64/lib${NAME}.a"
  _slice darwin amd64 "x86_64-apple-macos${MAC_MIN}" macosx "$OUT/macos-amd64/lib${NAME}.a"
  mkdir -p "$OUT/macos"
  lipo -create "$OUT/macos-arm64/lib${NAME}.a" "$OUT/macos-amd64/lib${NAME}.a" -output "$OUT/macos/lib${NAME}.a"
  cp "$OUT/macos-arm64/lib${NAME}.h" "$OUT/macos/lib${NAME}.h"

  # one include/ dir per slice for -create-xcframework
  for d in ios-arm64 ios-sim macos; do
    mkdir -p "$OUT/$d/include"
    cp "$OUT/$d/lib${NAME}.h" "$OUT/$d/include/"
  done

  rm -rf "$OUT/${NAME}.xcframework"
  xcodebuild -create-xcframework \
    -library "$OUT/ios-arm64/lib${NAME}.a" -headers "$OUT/ios-arm64/include" \
    -library "$OUT/ios-sim/lib${NAME}.a"   -headers "$OUT/ios-sim/include" \
    -library "$OUT/macos/lib${NAME}.a"     -headers "$OUT/macos/include" \
    -output "$OUT/${NAME}.xcframework"
  echo "→ $OUT/${NAME}.xcframework"
}

case "${1:-host}" in
  host) build_host ;;
  android) build_android ;;
  apple) build_apple ;;
  *) echo "usage: $0 [host|android|apple]"; exit 1 ;;
esac
echo "done."
