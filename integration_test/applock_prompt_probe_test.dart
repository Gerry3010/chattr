// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Audit M6/M7 — the "one prompt vs two" probe (interactive).
//
// The two-layer app-lock design is: a reliable `local_auth` challenge on resume
// (prompts even inside the keychain grace window), then the content-key read.
// The whole UX rests on ONE unverified assumption: that a SUCCESSFUL
// `local_auth.authenticate()` satisfies the `userPresence` of the FOLLOWING
// gated keychain read — so that read returns silently instead of raising a
// SECOND Face ID. If it doesn't, the assembled flow double-prompts and we need a
// native LAContext shim.
//
// This can only be answered interactively on real hardware:
//
//   flutter test integration_test/applock_prompt_probe_test.dart -d <device-id>
//
// Tap Face ID ONCE when the first prompt appears, then WATCH: does a second
// Face ID appear before the run prints its result?
//
// Isolated in its own keychain account; deploy under a THROWAWAY bundle id
// (net.geraldhofbauer.chattr.m6m7probe) so it never touches the prod container.

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:local_auth/local_auth.dart';

const _account = 'chattr_applock_prompt_probe';
const _probeKey = 'applock_prompt_probe';

const _gated = IOSOptions(
  accessibility: KeychainAccessibility.first_unlock_this_device,
  accountName: _account,
  accessControlFlags: [AccessControlFlag.userPresence],
);

// The production content-key account/key the native shim reads. On a separate
// bundle-id probe build this resolves to the PROBE app's OWN keychain group, so
// writing/reading here can never touch Gerry's prod app (different access group).
const _shimChannel = MethodChannel('net.geraldhofbauer.chattr/applock');
const _keyAccount = 'chattr_encryption';
const _keyItem = 'encryption_key_v1';
const _keyGated = IOSOptions(
  accessibility: KeychainAccessibility.first_unlock_this_device,
  accountName: _keyAccount,
  accessControlFlags: [AccessControlFlag.userPresence],
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const storage = FlutterSecureStorage();

  Future<void> wipe() async {
    try {
      await storage.delete(key: _probeKey, iOptions: _gated);
    } catch (_) {}
  }

  testWidgets('does local_auth satisfy the following gated read (one prompt)?',
      (tester) async {
    await wipe();
    await storage.write(key: _probeKey, value: 'probe-secret', iOptions: _gated);

    final auth = LocalAuthentication();
    // ignore: avoid_print
    print('[APPLOCK-PROBE] === TAP FACE ID ONCE when the prompt appears ===');
    var authOk = false;
    Object? authErr;
    try {
      authOk = await auth.authenticate(
        localizedReason: 'Chattr app-lock probe: confirm once',
        persistAcrossBackgrounding: true,
      );
    } catch (e) {
      authErr = e;
    }
    // ignore: avoid_print
    print('[APPLOCK-PROBE] local_auth: ok=$authOk err=$authErr');

    // The measurement: read the gated item with DEFAULT UI right after. If the
    // local_auth success carries into the keychain grace, this returns the value
    // in a few ms and NO second Face ID appears. If not, a second prompt shows
    // (watch the screen) and/or this blocks noticeably.
    final sw = Stopwatch()..start();
    String? value;
    Object? threw;
    try {
      value = await storage.read(key: _probeKey, iOptions: _gated);
    } catch (e) {
      threw = e;
    }
    sw.stop();

    // ignore: avoid_print
    print('[APPLOCK-PROBE] gated read after local_auth: value=$value '
        'elapsedMs=${sw.elapsedMilliseconds} threw=$threw');
    // ignore: avoid_print
    print('[APPLOCK-PROBE] INTERPRET: value="probe-secret" + elapsed small + NO '
        '2nd Face ID => ONE prompt (grace shared, design holds). '
        'A 2nd Face ID (or long elapsed) => TWO prompts (needs LAContext shim).');

    await wipe();
  });

  // The real verification of the assembled design: the native shim
  // (AppLockChannel) must do the challenge AND the gated read on ONE LAContext,
  // so the whole unlock (and the enable round-trip, same code path) is a SINGLE
  // Face ID. Runs against the probe app's own keychain group — never prod.
  testWidgets('shim: challenge + gated read = ONE Face ID', (tester) async {
    try {
      await const FlutterSecureStorage()
          .delete(key: _keyItem, iOptions: _keyGated);
    } catch (_) {}
    await const FlutterSecureStorage()
        .write(key: _keyItem, value: 'shim-probe-key', iOptions: _keyGated);

    // ignore: avoid_print
    print('[SHIM-PROBE] === invoking shim; TAP FACE ID ONCE, then WATCH for a '
        'SECOND prompt before the result prints ===');
    final sw = Stopwatch()..start();
    String? key;
    Object? err;
    try {
      key = await _shimChannel.invokeMethod<String>(
        'unlockAndReadContentKey',
        {'reason': 'Chattr shim probe: confirm once'},
      );
    } catch (e) {
      err = e;
    }
    sw.stop();

    // ignore: avoid_print
    print('[SHIM-PROBE] returned key=$key elapsedMs=${sw.elapsedMilliseconds} '
        'err=$err');
    // ignore: avoid_print
    print('[SHIM-PROBE] INTERPRET: key="shim-probe-key" AND exactly ONE Face ID '
        '=> the shim single-prompt design holds (enable round-trip + unlock are '
        'this same path). A 2nd Face ID => the shim did NOT share its context.');

    expect(key, 'shim-probe-key',
        reason: 'the shim must return the exact key it read');

    try {
      await const FlutterSecureStorage()
          .delete(key: _keyItem, iOptions: _keyGated);
    } catch (_) {}
  });
}
