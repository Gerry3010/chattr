// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:swipeable_page_route/swipeable_page_route.dart';

/// App-wide route factory: every pushed screen gets an iOS-style interactive
/// edge swipe-back that follows the finger and can be cancelled — and, unlike
/// [MaterialPageRoute], it also works on web and Android where there is
/// otherwise no back gesture at all.
///
/// The gesture is edge-only ([canOnlySwipeFromEdge]) so it doesn't fight
/// in-page horizontal gestures (media viewer, lists, the mobile chatview
/// timestamp swipe).
Route<T> appPageRoute<T>({
  required WidgetBuilder builder,
  RouteSettings? settings,
  bool fullscreenDialog = false,
  bool maintainState = true,
}) {
  return SwipeablePageRoute<T>(
    canOnlySwipeFromEdge: true,
    // Default is kMinInteractiveDimension (48). On iOS-PWA the OS claims the
    // outermost ~25-30px edge strip for its own history swipe, which would
    // leave almost nothing for our gesture — give web a wider start zone.
    backGestureDetectionWidth: kIsWeb ? 96 : kMinInteractiveDimension,
    builder: builder,
    settings: settings,
    fullscreenDialog: fullscreenDialog,
    maintainState: maintainState,
  );
}
