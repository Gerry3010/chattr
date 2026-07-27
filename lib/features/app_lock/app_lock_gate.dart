// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/lifecycle/app_lifecycle_service.dart';
import '../../screens/app_lock/lock_screen.dart';
import 'app_lock_controller.dart';

/// Wraps the whole app (via MaterialApp.builder) with the privacy blur and
/// the lock screen. Lifecycle mapping:
///  * inactive           → blur only (app switcher, permission dialogs)
///  * hidden / paused    → lock (re-auth required on return)
///  * resumed            → drop the blur; the lock stays until unlocked
class AppLockGate extends ConsumerStatefulWidget {
  final Widget child;

  const AppLockGate({super.key, required this.child});

  @override
  ConsumerState<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends ConsumerState<AppLockGate>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// The privacy blur is a mobile affordance (app-switcher preview, quick
  /// glances). Desktop emits `inactive` on every focus loss but does not
  /// reliably emit `resumed`, which would leave the blur stuck — so restrict
  /// the transient blur to mobile. The real lock (cold-start / paused) applies
  /// on every platform.
  static bool get _usesPrivacyBlur =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = ref.read(appLockControllerProvider.notifier);
    switch (state) {
      case AppLifecycleState.inactive:
        if (_usesPrivacyBlur) controller.setObscured(true);
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        controller.lock();
      case AppLifecycleState.resumed:
        controller.setObscured(false);
        // Catch up on anything missed while backgrounded: controllers listen to
        // this signal to reconnect realtime and re-fetch (see AppLifecycleService).
        ref.read(appLifecycleServiceProvider).notifyResumed();
      case AppLifecycleState.detached:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final lockState = ref.watch(appLockControllerProvider);

    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (lockState.obscured && !lockState.locked)
          // Privacy blur while momentarily inactive.
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
              child: ColoredBox(
                color: Theme.of(context)
                    .colorScheme
                    .surface
                    .withValues(alpha: 0.6),
              ),
            ),
          ),
        if (lockState.locked) const Positioned.fill(child: LockScreen()),
      ],
    );
  }
}
