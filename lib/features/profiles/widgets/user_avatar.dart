// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/navigation/app_page_route.dart';
import '../../identity/identity_color.dart';
import '../profile_helpers.dart';
import '../profiles_controller.dart';

/// Circular avatar for a user: shows their uploaded picture when available,
/// otherwise falls back to the first letter of their username.
class UserAvatar extends ConsumerWidget {
  final String userId;
  final double radius;

  /// Optional tap handler — e.g. [showAvatarViewer] to open the picture large.
  final VoidCallback? onTap;

  /// Optional override for the picture-less initials background. Defaults to the
  /// user's [IdentityColor] (audit M2) so the same user shows the SAME colour
  /// everywhere (chat list, header, member panel, search) and same-named users
  /// stay visibly distinct. The foreground letter is auto-contrasted.
  final Color? fallbackColor;

  const UserAvatar({
    super.key,
    required this.userId,
    this.radius = 20,
    this.onTap,
    this.fallbackColor,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider(userId));
    final url =
        ref.read(profilesControllerProvider.notifier).avatarUrl(profile?.avatarPath);
    final name = profile?.username ?? '?';
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';
    // Identity-derived colour by default → consistent for a given user across
    // every avatar site; callers can still override via [fallbackColor].
    final bg =
        fallbackColor ?? IdentityColor.forKeyOrId(profile?.identityPublicKey, userId);

    final Widget avatar = url != null
        ? CircleAvatar(
            radius: radius,
            backgroundImage: NetworkImage(url),
            onBackgroundImageError: (_, _) {},
            child: null,
          )
        : CircleAvatar(
            radius: radius,
            backgroundColor: bg,
            child: Text(
              initial,
              style: TextStyle(color: IdentityColor.foregroundOn(bg)),
            ),
          );

    if (onTap == null) return avatar;
    return GestureDetector(onTap: onTap, child: avatar);
  }
}

/// Opens a fullscreen, pinch-zoom viewer of a user's avatar. When the user has
/// no uploaded picture, shows a large initials circle instead (still a valid
/// "there's nothing bigger to see" state, dismissible via back).
void showAvatarViewer(BuildContext context, String userId) {
  Navigator.of(context).push(
    appPageRoute<void>(
      builder: (_) => _AvatarViewerScreen(userId: userId),
    ),
  );
}

class _AvatarViewerScreen extends ConsumerWidget {
  final String userId;

  const _AvatarViewerScreen({required this.userId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider(userId));
    final url = ref
        .read(profilesControllerProvider.notifier)
        .avatarUrl(profile?.avatarPath);
    final name = profile?.username ?? '?';
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(name),
      ),
      body: Center(
        child: url != null
            ? InteractiveViewer(
                boundaryMargin: const EdgeInsets.all(double.infinity),
                minScale: 0.8,
                maxScale: 5,
                child: Image.network(url),
              )
            : CircleAvatar(
                radius: 96,
                child: Text(initial, style: const TextStyle(fontSize: 72)),
              ),
      ),
    );
  }
}
