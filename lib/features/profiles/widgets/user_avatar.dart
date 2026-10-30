// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/navigation/app_page_route.dart';
import '../../identity/identity_color.dart';
import '../../media/widgets/fullscreen_image_viewer.dart';
import '../avatar_url_cache.dart';
import '../avatar_image.dart';
import '../profile_helpers.dart';

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

  /// Pass name, image path and identity key in directly instead of fetching
  /// them from the profile cache.
  ///
  /// Needed for people whose profile we may not (yet) read at all: with an open
  /// chat request we share no chat, and `00046` deliberately does not hand out
  /// a stranger's profile — `profileProvider` returned an empty profile there
  /// and the tile showed a "?" circle. In that case the data comes from
  /// `my_incoming_chat_requests()`.
  final String? overrideUsername;
  final String? overrideAvatarPath;
  final String? overrideIdentityKey;

  const UserAvatar({
    super.key,
    required this.userId,
    this.radius = 20,
    this.onTap,
    this.fallbackColor,
    this.overrideUsername,
    this.overrideAvatarPath,
    this.overrideIdentityKey,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile =
        overrideUsername == null ? ref.watch(profileProvider(userId)) : null;
    final avatarPath = overrideAvatarPath ?? profile?.avatarPath ?? '';
    // Signed and short-lived (00075): null on the first build, then the
    // picture — the initials circle below is the intended in-between.
    // Signed and short-lived (00075), from the disk cache when there is no
    // URL (CHAT-63): null only when there is no picture to show at all.
    final image = ref.watch(avatarImageProvider(
      (bucket: kAvatarBucket, path: avatarPath),
    ));
    final name = overrideUsername ?? profile?.username ?? '?';
    final initial = initialsFor(name);
    // Identity-derived colour by default → consistent for a given user across
    // every avatar site; callers can still override via [fallbackColor].
    final bg = fallbackColor ??
        IdentityColor.forKeyOrId(
          overrideIdentityKey ?? profile?.identityPublicKey,
          userId,
        );

    final Widget avatar = image != null
        ? CircleAvatar(
            radius: radius,
            backgroundImage: image,
            onBackgroundImageError: (_, _) {},
            child: null,
          )
        : CircleAvatar(
            radius: radius,
            backgroundColor: bg,
            child: Text(
              initial,
              style: IdentityColor.initialsTextStyle(radius, bg),
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
    final image = ref.watch(avatarImageProvider(
      (bucket: kAvatarBucket, path: profile?.avatarPath ?? ''),
    ));
    final name = profile?.username ?? '?';
    final initial = initialsFor(name);
    // Same identity colour as every other avatar surface (was the theme's
    // default CircleAvatar colour — a fourth look for the same user).
    final bg = IdentityColor.forKeyOrId(profile?.identityPublicKey, userId);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(name),
      ),
      body: Center(
        child: image != null
            ? DismissibleElasticImage(image: image)
            : CircleAvatar(
                radius: 96,
                backgroundColor: bg,
                child: Text(
                  initial,
                  style: IdentityColor.initialsTextStyle(96, bg),
                ),
              ),
      ),
    );
  }
}
