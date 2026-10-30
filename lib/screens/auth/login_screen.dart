// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import '../../core/navigation/app_page_route.dart';
import '../../core/theme/chattr_logo.dart';
import '../../features/profile/username_rules.dart';
import '../../features/auth/auth_controller.dart';
import 'recovery_screen.dart';

class LoginScreen extends HookConsumerWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final usernameController = useTextEditingController();
    final isLoading = useState(false);

    Future<void> handleLogin() async {
      // The field already truncates; this check catches the rest — a name made
      // only of spaces, and anything that gets past the field to here in
      // future.
      if (!isValidUsername(usernameController.text)) {
        final empty = usernameController.text.trim().isEmpty;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(empty
                ? 'login.error_empty_username'.tr()
                : 'settings.username_invalid'.tr()),
          ),
        );
        return;
      }

      isLoading.value = true;
      try {
        // Anonymous Auth + Profile Creation in one step
        await ref.read(authControllerProvider.notifier).loginWithUsername(
          usernameController.text.trim(),
        );
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('login.error_failed'.tr(args: [e.toString()]))),
          );
        }
      } finally {
        isLoading.value = false;
      }
    }

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Logo / Title
              const Center(child: ChattrLogo(size: 96)),
              const SizedBox(height: 16),
              Text(
                'app_name'.tr(),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                'login.tagline'.tr(),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.grey[600],
                    ),
              ),
              const SizedBox(height: 48),

              // Username Input
              TextField(
                controller: usernameController,
                // The same limit as for renaming later (settings_screen.dart).
                // It was missing here — and this is exactly where the name
                // comes into being: on 2026-08-29 an iOS device created an
                // account with a **5469 character** name, the content of a
                // pasted documentation page. The editing field would have
                // truncated it; the creation field took everything.
                maxLength: kMaxUsernameLength,
                // The counter under the field would be mere noise at sign-in —
                // it belongs to a field in which one wrestles for room, and
                // here one writes a first name.
                buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
                decoration: InputDecoration(
                  labelText: 'login.username_label'.tr(),
                  hintText: 'login.username_hint'.tr(),
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.person_outline),
                ),
                // Above a name field the word-suggestion bar has no business:
                // iOS offers whole sentence openings there, and whoever taps
                // one is afterwards called "I'm not sure" or "The most
                // important thing" — 47 such accounts lay on the server on
                // 2026-08-16. Autocorrect is worse still, it CHANGES an already
                // typed name on submit.
                autocorrect: false,
                enableSuggestions: false,
                textCapitalization: TextCapitalization.none,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => handleLogin(),
                enabled: !isLoading.value,
              ),
              const SizedBox(height: 24),

              // Login Button
              FilledButton(
                onPressed: isLoading.value ? null : handleLogin,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16.0),
                  child: isLoading.value
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text('login.button'.tr()),
                ),
              ),
              const SizedBox(height: 8),

              // Recover an existing identity from a recovery phrase.
              TextButton(
                key: const ValueKey('login_recover_button'),
                onPressed: isLoading.value
                    ? null
                    : () => Navigator.push(
                          context,
                          appPageRoute<void>(builder: (_) => const RecoveryScreen()),
                        ),
                child: Text('login.recover_link'.tr()),
              ),
              const SizedBox(height: 8),

              // Info Text
              Text(
                'login.privacy_info'.tr(),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.grey[600],
                    ),
              ),
              const SizedBox(height: 6),
              // That the server clears away dormant accounts belongs where one
              // comes into being — not only in the privacy policy. Signing in
              // ALWAYS creates a new account here; whoever does that just to
              // have a look should know that it disappears again by itself.
              Text(
                'login.dormant_info'.tr(),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.grey[600],
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
