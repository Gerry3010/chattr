// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Flutter
import LocalAuthentication
import Security
import UIKit

/// Native app-lock unlock shim (audit M6/M7).
///
/// The content key is stored bound to the keychain `userPresence` access-control
/// (the at-rest layer). The UX challenge on resume must be a reliable prompt —
/// but a device-measured grace window means the keychain read does NOT reliably
/// prompt on an already-unlocked device, and a separate `local_auth` prompt does
/// NOT share its authentication with a subsequent `flutter_secure_storage` read
/// (device-measured: two Face ID prompts).
///
/// The fix is to keep BOTH steps on ONE `LAContext`: evaluate the policy (the
/// prompt) and then read the gated key with `kSecUseAuthenticationContext` set to
/// that same, now-authenticated context. iOS accepts the context for the item's
/// ACL, so the read does not prompt again — one Face ID total.
///
/// The keychain query mirrors how `flutter_secure_storage_darwin` stores the
/// item (`accountName` → `kSecAttrService`, the storage key → `kSecAttrAccount`,
/// class GenericPassword), so this reads the EXACT item the Dart side wrote.
enum AppLockChannel {
  static let channelName = "net.geraldhofbauer.chattr/applock"

  // Must match EncryptionKeyManager: accountName + storage key.
  private static let keychainService = "chattr_encryption"
  private static let keychainAccount = "encryption_key_v1"

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "unlockAndReadContentKey":
        let args = call.arguments as? [String: Any]
        let reason = (args?["reason"] as? String) ?? "Unlock Chattr"
        unlockAndReadContentKey(reason: reason, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func unlockAndReadContentKey(
    reason: String, result: @escaping FlutterResult
  ) {
    let context = LAContext()
    context.localizedReason = reason

    // The reliable challenge — prompts even when the device is already unlocked.
    // deviceOwnerAuthentication = biometry with device-passcode fallback, which
    // is exactly what satisfies a `userPresence` ACL.
    context.evaluatePolicy(
      .deviceOwnerAuthentication, localizedReason: reason
    ) { success, evalError in
      if !success {
        let code: String
        switch (evalError as? LAError)?.code {
        case .userCancel, .appCancel, .systemCancel:
          code = "userCancel"
        case .userFallback:
          code = "userFallback"
        case .biometryNotAvailable, .biometryNotEnrolled, .passcodeNotSet:
          code = "unavailable"
        default:
          code = "authFailed"
        }
        DispatchQueue.main.async {
          result(FlutterError(
            code: code, message: evalError?.localizedDescription, details: nil))
        }
        return
      }

      // Authenticated. Read the gated key on the SAME context so the item's
      // userPresence ACL is already satisfied — no second prompt.
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: keychainService,
        kSecAttrAccount as String: keychainAccount,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
        kSecUseAuthenticationContext as String: context,
      ]
      var item: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &item)

      DispatchQueue.main.async {
        if status == errSecSuccess,
           let data = item as? Data,
           let key = String(data: data, encoding: .utf8) {
          result(key)
        } else if status == errSecItemNotFound {
          // No gated key present (app lock on but key not migrated, or the key
          // is ungated). Signal null so Dart falls back to its normal read.
          result(nil)
        } else {
          result(FlutterError(
            code: "keychain",
            message: "SecItemCopyMatching failed",
            details: Int(status)))
        }
      }
    }
  }
}
