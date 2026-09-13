// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../core/navigation/app_page_route.dart';
import '../../features/chat_requests/widgets/chat_request_action_tile.dart';
import '../../features/identity/identity_verification_controller.dart';
import '../../features/identity/identity_verification_repository.dart';
import '../../features/identity/widgets/trust_shield.dart';
import '../../features/profiles/profile_helpers.dart';
import '../../features/profiles/widgets/important_person_tile.dart';
import '../../features/profiles/widgets/user_avatar.dart';
import 'safety_number_screen.dart';

/// A person — not a chat.
///
/// Until 1.26 this screen did not exist, and a group member's profile sheet
/// said explicitly in a comment that there is no deeper place it could point
/// to: a profile held nothing beyond name, picture and identity key. That is no
/// longer true now that one can request a 1:1 chat from here — and the route to
/// it is exactly the one Gerry described: tap a member in the group.
class PersonProfileScreen extends ConsumerWidget {
  final String userId;

  /// A name from a row, when we may not (yet) read the profile — for instance
  /// with an open request from somebody we share no chat with (`00046`).
  final String? fallbackName;

  const PersonProfileScreen({
    super.key,
    required this.userId,
    this.fallbackName,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider(userId));
    final name = profile?.username ?? fallbackName ?? '';
    final verification = ref.watch(peerVerificationProvider(userId));

    return Scaffold(
      appBar: AppBar(title: Text('chat_requests.profile_title'.tr())),
      body: ListView(
        children: [
          const SizedBox(height: 24),
          Center(
            child: UserAvatar(
              userId: userId,
              radius: 48,
              overrideUsername: profile == null ? fallbackName : null,
              onTap: () => showAvatarViewer(context, userId),
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: Text(
              name.isEmpty ? 'chat_detail.unknown_user'.tr() : name,
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: TrustStatusChip(
              appearance: trustAppearanceFor(
                verification.asData?.value ??
                    IdentityVerificationState.unknown,
              ),
            ),
          ),
          const SizedBox(height: 20),
          const Divider(height: 1),
          ChatRequestActionTile(peerId: userId),
          ImportantPersonTile(userId: userId),
          ListTile(
            leading: const Icon(Icons.verified_user_outlined),
            title: Text('profile.verify'.tr()),
            onTap: () => Navigator.push(
              context,
              appPageRoute<void>(
                builder: (_) => SafetyNumberScreen(
                  userId: userId,
                  username: name,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
