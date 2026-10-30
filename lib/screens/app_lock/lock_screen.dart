// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/lifecycle/app_lifecycle_service.dart';
import '../../core/logging/logger_service.dart';
import '../../features/app_lock/app_lock_controller.dart';

/// Full-screen lock overlay: tries biometrics automatically when available,
/// falls back to the passcode field otherwise.
class LockScreen extends ConsumerStatefulWidget {
  const LockScreen({super.key});

  @override
  ConsumerState<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<LockScreen> {
  final _passcodeController = TextEditingController();
  bool _biometricsAvailable = false;

  /// Focused explicitly once the biometric check says there is no other way
  /// in. It used to be `autofocus: !_biometricsAvailable`, which on the first
  /// frame was always true (the check is asynchronous): the lock screen
  /// appears while the app goes to the background, so the passcode field took
  /// the focus out of the chat's text field unseen, and after Face ID the
  /// keyboard came back bound to nothing (CHAT-12/CHAT-53).
  final FocusNode _passcodeFocus = FocusNode(debugLabel: 'app_lock_passcode');
  bool _wrongPasscode = false;
  bool _busy = false;
  String? _unlockError;
  StreamSubscription<void>? _resumeSub;

  /// Locked because a data gate failed (Face ID cancelled at start), not
  /// because app lock is switched on.
  bool get _isGateLock => !ref.read(appLockControllerProvider).enabled;

  @override
  void initState() {
    super.initState();
    _initUnlock();
    // A gate lock asks again when the user comes back to the app, the way
    // the start did. App lock proper gets a fresh lock screen on every
    // return and prompts from initState, so it needs nothing here.
    _resumeSub = ref.read(appLifecycleServiceProvider).onReturn.listen((_) {
      final lock = ref.read(appLockControllerProvider);
      if (mounted && lock.locked && !lock.enabled && _biometricsAvailable) {
        _tryBiometrics();
      }
    });
  }

  @override
  void dispose() {
    _resumeSub?.cancel();
    _passcodeController.dispose();
    _passcodeFocus.dispose();
    super.dispose();
  }

  Future<void> _initUnlock() async {
    final controller = ref.read(appLockControllerProvider.notifier);
    final available = await controller.biometricsAvailable();
    if (!mounted) return;
    setState(() => _biometricsAvailable = available);
    if (!available && ref.read(appLockControllerProvider).hasPasscode) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _passcodeFocus.requestFocus();
      });
    }
    // A gate lock appears right after the user cancelled Face ID. Asking
    // again at once would fight that; the button is one tap away.
    if (available && !_isGateLock) {
      await _tryBiometrics();
    } else if (!available && !ref.read(appLockControllerProvider).hasPasscode) {
      // No unlock method left at all — never lock the user out.
      controller.forceUnlockWithoutMethod();
    }
  }

  Future<void> _tryBiometrics() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _unlockError = null;
    });
    final controller = ref.read(appLockControllerProvider.notifier);
    var ok = false;
    try {
      ok = await controller.unlockWithBiometrics(
        localizedReason: 'app_lock.unlock_reason'.tr(),
      );
    } catch (e) {
      // Any error MUST leave a usable screen. A MissingPluginException (e.g. the
      // native channel failed to register) escapes both the controller's and the
      // shim's typed catches; without this, _busy would stay true and every
      // unlock control would be permanently dead — a hard lockout from one's own
      // data. Reset below in finally and offer a retry.
      logger.warning('Biometric unlock failed', error: e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    if (ok) {
      _onUnlocked();
    } else {
      setState(() => _unlockError = 'app_lock.unlock_failed'.tr());
    }
  }

  Future<void> _tryPasscode() async {
    if (_busy) return;
    final passcode = _passcodeController.text;
    if (passcode.isEmpty) return;
    setState(() {
      _busy = true;
      _unlockError = null;
    });
    final controller = ref.read(appLockControllerProvider.notifier);
    var ok = false;
    try {
      ok = await controller.unlockWithPasscode(passcode);
    } catch (e) {
      logger.warning('Passcode unlock failed', error: e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    final wait = ok ? Duration.zero : await controller.passcodeLockout();
    if (!mounted) return;
    setState(() {
      _wrongPasscode = !ok;
      _unlockError = wait > Duration.zero
          ? 'app_lock.too_many_attempts'
              .tr(args: ['${wait.inSeconds + 1}'])
          : null;
    });
    if (ok) {
      _onUnlocked();
    } else {
      _passcodeController.clear();
    }
  }

  /// After a successful unlock, re-fire the resume catch-up. The gate's
  /// `resumed → notifyResumed()` ran while we were still locked, so its resync
  /// hit the locked key and persisted nothing (the watermark was correctly
  /// capped). Firing it again now that the key is unlocked pulls in the messages
  /// that arrived while away, without a manual chat reopen (audit M6/M7).
  void _onUnlocked() {
    ref.read(appLifecycleServiceProvider).notifyResumed();
  }

  @override
  Widget build(BuildContext context) {
    final lockState = ref.watch(appLockControllerProvider);
    final theme = Theme.of(context);

    return Material(
      color: theme.colorScheme.surface,
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.lock_outline,
                      size: 56, color: theme.colorScheme.primary),
                  const SizedBox(height: 16),
                  Text(
                    'app_lock.locked_title'.tr(),
                    style: theme.textTheme.titleLarge,
                    textAlign: TextAlign.center,
                  ),
                  if (!lockState.enabled) ...[
                    const SizedBox(height: 8),
                    Text(
                      'app_lock.gate_hint'.tr(),
                      style: theme.textTheme.bodyMedium,
                      textAlign: TextAlign.center,
                    ),
                  ],
                  const SizedBox(height: 24),
                  if (lockState.hasPasscode) ...[
                    TextField(
                      key: const ValueKey('app_lock_passcode_field'),
                      controller: _passcodeController,
                      obscureText: true,
                      focusNode: _passcodeFocus,
                      keyboardType: TextInputType.number,
                      textAlign: TextAlign.center,
                      decoration: InputDecoration(
                        // Deliberately no min-length hint here: the policy
                        // belongs to setup only (leaks entropy to an attacker).
                        hintText: 'app_lock.unlock_hint'.tr(),
                        errorText: _wrongPasscode
                            ? 'app_lock.wrong_passcode'.tr()
                            : null,
                        border: const OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => _tryPasscode(),
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      key: const ValueKey('app_lock_unlock_button'),
                      onPressed: _busy ? null : _tryPasscode,
                      child: Text('app_lock.unlock'.tr()),
                    ),
                  ],
                  if (_unlockError != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _unlockError!,
                      style: TextStyle(color: theme.colorScheme.error),
                      textAlign: TextAlign.center,
                    ),
                  ],
                  if (_biometricsAvailable) ...[
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _tryBiometrics,
                      icon: const Icon(Icons.fingerprint),
                      label: Text('app_lock.use_biometrics'.tr()),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
