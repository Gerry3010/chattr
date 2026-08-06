// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/legacy.dart';

/// The chat currently on screen — set by `ChatViewScreen` ONLY while it is the
/// top-most route, `null` otherwise (incl. when a sub-screen of the same chat
/// — details, image/avatar viewer — is pushed on top). Managed via
/// [chatViewRouteObserver] so notifications for that chat stay live everywhere
/// except the chat view itself.
///
/// Used to suppress the in-app notification banner + chime for messages
/// arriving in the chat the user is already looking at (they see the message
/// appear live; a banner would be noise).
final activeChatProvider = StateProvider<String?>((ref) => null);

/// Observes route pushes/pops so [ChatViewScreen] can drop/restore its
/// active-chat suppression when a sub-screen is pushed on top of it. Registered
/// in the app's `navigatorObservers`.
final RouteObserver<PageRoute<dynamic>> chatViewRouteObserver =
    RouteObserver<PageRoute<dynamic>>();
