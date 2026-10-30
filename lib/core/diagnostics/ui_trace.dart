// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/widgets.dart';

import '../logging/logger_service.dart';

/// A trail of what the UI did, in the dev log (tap the version 7×).
///
/// Written for CHAT-53: after coming back from the app switcher an open chat
/// showed banners for its own messages (so `activeChatProvider` had been
/// cleared) and the keyboard stood up without a focused field. Nothing in the
/// code explained either, and neither shows up in a simulator on demand. With
/// this trail the next occurrence says what moved: a route, the focus, or the
/// active chat, and in which lifecycle state. Ids are shortened; no content.
const String uiTraceTag = 'UiTrace';

String shortId(String? id) =>
    id == null ? '–' : (id.length > 8 ? id.substring(0, 8) : id);

String _describe(Route<dynamic>? route) {
  if (route == null) return '–';
  final name = route.settings.name;
  return '${route.runtimeType}${name == null ? '' : '($name)'}';
}

/// Logs every navigator move. Cheap: a line per push/pop, no payloads.
class UiTraceRouteObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      logger.info('push ${_describe(route)} over ${_describe(previousRoute)}',
          tag: uiTraceTag);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      logger.info('pop ${_describe(route)} back to ${_describe(previousRoute)}',
          tag: uiTraceTag);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      logger.info('remove ${_describe(route)}', tag: uiTraceTag);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      logger.info('replace ${_describe(oldRoute)} with ${_describe(newRoute)}',
          tag: uiTraceTag);
}

final UiTraceRouteObserver uiTraceRouteObserver = UiTraceRouteObserver();

bool _focusTraceInstalled = false;
String? _lastFocus;

/// Logs whenever the primary focus moves to a different node.
void installFocusTrace() {
  if (_focusTraceInstalled) return;
  _focusTraceInstalled = true;
  FocusManager.instance.addListener(() {
    final node = FocusManager.instance.primaryFocus;
    final label = node == null
        ? 'none'
        : (node.debugLabel ?? node.context?.widget.runtimeType.toString() ??
            node.runtimeType.toString());
    if (label == _lastFocus) return;
    logger.info('focus $_lastFocus → $label', tag: uiTraceTag);
    _lastFocus = label;
  });
}
