#!/usr/bin/env bash
# Captures a fresh Chattr cold start on the Galaxy and filters the
# keystore/secure-storage/crypto lines (root cause "No private key").
# Prerequisite: the Galaxy attached by USB (adb device); the screen may come on
# in the process.
set -euo pipefail
PKG=net.geraldhofbauer.chattr
OUT="${1:-/home/gerry/.claude/jobs/tmp/galaxy-coldstart-$(date +%s).log}"
adb shell am force-stop "$PKG"
adb logcat -c                      # Puffer leeren → nur der frische Start
adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null
echo "App gestartet — sammle 25s logcat → $OUT"
timeout 25 adb logcat > "$OUT" || true
echo "=== Krypto/Keystore/SecureStorage/Flutter-Fehler ==="
grep -iE "keystore|keymaster|SecureStorage|EncryptedSharedPref|InvalidKey|BadPadding|AEADBadTag|javax.crypto|Decryption failed|No private key|IdentityKey|KemKey|deleteAll|check_sys_key|KeyPermanentlyInvalidated|UnlockedDeviceRequired" "$OUT" || echo "(nichts gematcht — Filter ggf. weiten)"
