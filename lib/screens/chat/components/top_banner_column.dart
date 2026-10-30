// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/widgets.dart';

/// Banners stacked above a screen whose own top bar pads for the status bar.
///
/// Each banner pads itself (SafeArea) because it may be the top-most thing on
/// screen. Whatever sits below a visible banner must not pad again, or the
/// status-bar inset shows up twice: an empty band between the banner and the
/// chat's app bar (Gerry's iPhone with the server banner, 2026-10-29). Before,
/// the chat view stripped the inset for the membership banner only.
///
/// The tree has the same shape whether a banner shows or not, so [child]
/// keeps its state when the connection drops and comes back.
class TopBannerColumn extends StatelessWidget {
  const TopBannerColumn({
    super.key,
    required this.banners,
    required this.child,
  });

  /// Top to bottom, each with whether it currently shows. The flag must come
  /// from the same source the banner renders from, or the inset is lost or
  /// doubled again.
  final List<({Widget banner, bool visible})> banners;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    var insetTaken = false;
    final children = <Widget>[];
    for (final entry in banners) {
      children.add(MediaQuery.removePadding(
        context: context,
        removeTop: insetTaken,
        child: entry.banner,
      ));
      insetTaken = insetTaken || entry.visible;
    }
    children.add(Expanded(
      child: MediaQuery.removePadding(
        context: context,
        removeTop: insetTaken,
        child: child,
      ),
    ));
    return Column(children: children);
  }
}
