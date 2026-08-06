// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Audit M6/M7 — probe, not a regression test.
//
// The M6/M7 design (gate the content key behind userPresence) rests on two
// claims about how flutter_secure_storage and the iOS Keychain actually behave.
// Neither can be read out of the source: the ACL lives inside the encrypted item
// blob, and the simulator keychain has no column exposing it (unlike M5, where
// `pdmn` made the proof trivial). So we measure.
//
// Q1 — Does a gated read see a NON-gated item?
//   The plugin puts kSecAttrAccessControl into the SEARCH query
//   (FlutterSecureStorage.swift baseQuery), which would make a gated read miss
//   an older ungated item — exactly the trap M5 sprang, one layer up, and the
//   reason the migration cascade exists. But Apple treats kSecAttrAccessControl
//   as questionable in a query, so iOS may simply ignore it while searching.
//   If it does, the cascade's fallback never runs — and the item silently keeps
//   NO ACL. The gate would be a no-op that passes every functional test.
//
// Q2 — Which string arms kSecUseAuthenticationUI?
//   IOSOptions.authenticationUIBehavior is a raw String?, not an enum, and the
//   plugin passes it straight through. `hasKey()` needs it to ask "does the item
//   exist?" WITHOUT prompting — otherwise a cold start demands Face ID, and the
//   answer to a cancelled prompt would flow into app_init.dart:130, where a
//   false reading makes generateKey() overwrite the key. Wrong string = silently
//   no effect = we prompt anyway.
//
// Neither question needs Face ID enrolled: writing an ACL item and searching for
// it does not authenticate — only reading its VALUE does. That keeps this probe
// runnable headless.
//
//   flutter test integration_test/keychain_acl_probe_test.dart -d <simulator-id>
//
// Simulator only — writes real Keychain items.

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _probeKey = 'm6m7_acl_probe';
const _account = 'chattr_m6m7_probe';

const _ungated = IOSOptions(
  accessibility: KeychainAccessibility.first_unlock_this_device,
  accountName: _account,
);

const _gated = IOSOptions(
  accessibility: KeychainAccessibility.first_unlock_this_device,
  accountName: _account,
  accessControlFlags: [AccessControlFlag.userPresence],
);

/// The two protection classes worth pairing with userPresence, measured in one
/// run so a wrong guess does not cost a second device trip.
///
/// `unlocked_this_device` is the canonical pairing (the key is never needed
/// while the device is locked — there is no background decrypt). The current
/// `first_unlock_this_device` is semantically odd next to userPresence
/// (readable-while-locked vs. requires-presence), and if
/// SecAccessControlCreateWithFlags rejects it, the plugin silently writes the
/// item with NO ACL. Both are probed; the one that enforces wins.
///
/// `passcode` is deliberately absent: it maps to WhenPasscodeSetThisDeviceOnly,
/// where iOS DELETES the item once the user removes their passcode.
const _classes = <String, KeychainAccessibility>{
  'unlocked_this_device': KeychainAccessibility.unlocked_this_device,
  'first_unlock_this_device': KeychainAccessibility.first_unlock_this_device,
};

/// Candidate raw values for kSecUseAuthenticationUI. The Dart API takes a plain
/// String and the plugin forwards it as the CF value unmapped, so the exact
/// underlying constant matters and is not documented as stable. Guessing is the
/// thing this probe exists to avoid — try both, let the device decide.
const _uiSuppressCandidates = <String>['fail', 'u_AuthUIF'];

IOSOptions _opts(
  KeychainAccessibility acc, {
  bool gated = false,
  String? uiBehavior,
}) =>
    IOSOptions(
      accessibility: acc,
      accountName: _account,
      accessControlFlags: gated ? const [AccessControlFlag.userPresence] : const [],
      authenticationUIBehavior: uiBehavior,
    );

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const storage = FlutterSecureStorage();

  Future<void> wipe() async {
    for (final o in [_ungated, _gated]) {
      try {
        await storage.delete(key: _probeKey, iOptions: o);
      } catch (_) {
        // A gated delete can throw if the item is locked; the other option
        // covers it. Never let cleanup mask the measurement.
      }
    }
  }

  setUp(wipe);
  tearDownAll(wipe);

  testWidgets('Q1: does a gated read see an ungated item?', (tester) async {
    await storage.write(key: _probeKey, value: 'ungated-value', iOptions: _ungated);

    String? viaGated;
    Object? threw;
    try {
      viaGated = await storage.read(key: _probeKey, iOptions: _gated);
    } catch (e) {
      threw = e;
    }

    // Not an assertion — a measurement. Both outcomes are legal and each one
    // dictates a different design, so record rather than judge.
    // ignore: avoid_print
    print('[M6M7-PROBE] Q1 gated-read-of-ungated: value=$viaGated threw=$threw');

    final viaUngated = await storage.read(key: _probeKey, iOptions: _ungated);
    expect(viaUngated, 'ungated-value',
        reason: 'sanity: the ungated read must still find its own item');
  });

  testWidgets('Q1b: does an ungated read see a gated item?', (tester) async {
    // The reverse direction decides whether the OLD read path could keep
    // serving the key after migration — which would defeat the gate entirely.
    await storage.write(key: _probeKey, value: 'gated-value', iOptions: _gated);

    String? viaUngated;
    Object? threw;
    try {
      viaUngated = await storage.read(key: _probeKey, iOptions: _ungated);
    } catch (e) {
      threw = e;
    }
    // ignore: avoid_print
    print('[M6M7-PROBE] Q1b ungated-read-of-gated: value=$viaUngated threw=$threw');

    // If this returns the value with no prompt, the ACL buys us nothing while
    // any ungated read path survives anywhere in the codebase.
  });

  testWidgets('Q2: which string arms kSecUseAuthenticationUI?', (tester) async {
    await storage.write(key: _probeKey, value: 'gated-value', iOptions: _gated);

    for (final candidate in _uiSuppressCandidates) {
      final probing = IOSOptions(
        accessibility: KeychainAccessibility.first_unlock_this_device,
        accountName: _account,
        accessControlFlags: const [AccessControlFlag.userPresence],
        authenticationUIBehavior: candidate,
      );

      String? value;
      String? code;
      Object? details;
      try {
        value = await storage.read(key: _probeKey, iOptions: probing);
      } on PlatformException catch (e) {
        code = e.code;
        details = e.details; // carries the OSStatus
      } catch (e) {
        code = e.runtimeType.toString();
      }
      // errSecInteractionNotAllowed (-25308) => armed: item exists, no prompt.
      // A returned value with no ACL in play => the write silently produced an
      // unprotected item (the createAccessControl-returns-nil path).
      // ignore: avoid_print
      print('[M6M7-PROBE] Q2 "$candidate": value=$value code=$code details=$details');
    }
  });

  testWidgets('Q3: does writing a gated item actually attach an ACL?',
      (tester) async {
    // The silent-downgrade check. If SecAccessControlCreateWithFlags rejects
    // first_unlock_this_device + userPresence, the plugin logs and writes the
    // item WITHOUT protection — no error surfaces. Reading it back without any
    // authentication would then succeed, which is the tell.
    await storage.write(key: _probeKey, value: 'gated-value', iOptions: _gated);

    String? value;
    Object? threw;
    try {
      value = await storage.read(key: _probeKey, iOptions: _gated);
    } catch (e) {
      threw = e;
    }
    // On a simulator with NO biometrics/passcode enrolled, a genuine ACL read
    // cannot succeed silently. A plain value here means the ACL never attached.
    // ignore: avoid_print
    print('[M6M7-PROBE] Q3 gated-read-of-gated (no auth set up): '
        'value=$value threw=$threw');
  });

  // ── The one device run ────────────────────────────────────────────────────
  //
  // Everything above is settled or unmeasurable on a simulator: matching (Q1)
  // needs no Secure Enclave and is already answered, while enforcement needs
  // real hardware — a simulator returns the value either way, so it cannot tell
  // an attached ACL from a silently dropped one.
  //
  // This matrix is built to answer all three enforcement questions in a SINGLE
  // pass on Gerry's iPhone, because every iteration costs a device round-trip:
  //
  //   • Does the ACL actually attach?  gated + suppressed-UI read → -25308,
  //     versus ungated + suppressed-UI read → value. That difference IS the
  //     proof; identical results mean the ACL never attached.
  //   • Which protection class survives SecAccessControlCreateWithFlags?
  //   • Which raw string arms kSecUseAuthenticationUI?
  //
  // Nothing here prompts: suppressing the UI turns "needs auth" into an error
  // instead of a dialog, so the run stays headless and scriptable.
  testWidgets('DEVICE MATRIX: classes × gated/ungated × UI-suppress strings',
      (tester) async {
    for (final entry in _classes.entries) {
      final className = entry.key;
      for (final gated in [true, false]) {
        for (final ui in _uiSuppressCandidates) {
          await wipe();
          await storage.write(
            key: _probeKey,
            value: 'probe',
            iOptions: _opts(entry.value, gated: gated),
          );

          String? value;
          Object? details;
          String? code;
          try {
            value = await storage.read(
              key: _probeKey,
              iOptions: _opts(entry.value, gated: gated, uiBehavior: ui),
            );
          } on PlatformException catch (e) {
            code = e.code;
            details = e.details; // OSStatus: -25308 = interactionNotAllowed
          } catch (e) {
            code = e.runtimeType.toString();
          }

          // ignore: avoid_print
          print('[M6M7-MATRIX] class=$className gated=$gated ui="$ui" '
              '=> value=$value code=$code details=$details');
        }
      }
    }
    // Deliberately assertion-free: this measures, it does not judge. Reading a
    // verdict into the matrix before seeing it is exactly the habit that keeps
    // producing green signals for the wrong reason.
  });
}
