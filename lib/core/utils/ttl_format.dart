// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';

/// Human-readable label for a disappearing-messages TTL, e.g. "5 Minuten".
///
/// Lives in `core/` because two unrelated places need the exact same wording:
/// the chat-detail picker that sets the TTL, and the system message that
/// announces the change to every member. The announcement carries the raw
/// seconds over the wire (not a rendered string) so each device formats it in
/// its own locale.
String formatMessageTtl(int seconds) {
  if (seconds < 60) return 'chat_detail.ttl_seconds'.tr(args: ['$seconds']);
  if (seconds < 3600) {
    return 'chat_detail.ttl_minutes'.tr(args: ['${seconds ~/ 60}']);
  }
  if (seconds < 86400) {
    return 'chat_detail.ttl_hours'.tr(args: ['${seconds ~/ 3600}']);
  }
  if (seconds < 604800) {
    return 'chat_detail.ttl_days'.tr(args: ['${seconds ~/ 86400}']);
  }
  return 'chat_detail.ttl_weeks'.tr(args: ['${seconds ~/ 604800}']);
}
