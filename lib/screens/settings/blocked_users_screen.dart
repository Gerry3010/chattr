// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/blocks/blocked_users_repository.dart';
import '../../features/profiles/profile_helpers.dart';
import '../../features/profiles/widgets/user_avatar.dart';
import '../../core/network/load_error_view.dart';

/// Lists the users blocked by the current user, with per-row unblock.
class BlockedUsersScreen extends ConsumerWidget {
  const BlockedUsersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final blockedAsync = ref.watch(blockedUserIdsProvider);

    return Scaffold(
      appBar: AppBar(title: Text('blocked.title'.tr())),
      body: blockedAsync.when(
        data: (userIds) => userIds.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'blocked.empty'.tr(),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ),
              )
            : ListView.builder(
                itemCount: userIds.length,
                itemBuilder: (context, index) =>
                    _BlockedUserTile(userId: userIds[index]),
              ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => LoadErrorView(
          error: err,
          onRetry: () => ref.invalidate(blockedUserIdsProvider),
        ),
      ),
    );
  }
}

class _BlockedUserTile extends ConsumerWidget {
  final String userId;

  const _BlockedUserTile({required this.userId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider(userId));

    return ListTile(
      leading: UserAvatar(userId: userId, radius: 20),
      title: Text(profile?.username ?? 'chat_detail.unknown_user'.tr()),
      trailing: TextButton(
        onPressed: () async {
          final messenger = ScaffoldMessenger.of(context);
          try {
            await ref.read(blockedUsersRepositoryProvider).unblock(userId);
            ref.invalidate(blockedUserIdsProvider);
            messenger.showSnackBar(
              SnackBar(content: Text('blocked.unblocked_success'.tr())),
            );
          } catch (e) {
            messenger.showSnackBar(
              SnackBar(content: Text('common.error'.tr(args: ['$e']))),
            );
          }
        },
        child: Text('blocked.unblock'.tr()),
      ),
    );
  }
}
