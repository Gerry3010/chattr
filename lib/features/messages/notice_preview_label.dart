// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';

import '../../core/crypto/envelope_version.dart';
import '../../core/crypto/undecryptable_notice.dart';

/// The one-line label for a stand-in notice (a message this device cannot
/// open, or one from a newer build), for reply quotes, search and
/// notifications. Null when [content] is no notice, so callers chain it in
/// front like `shotPreviewLabel`. Without it those places show the raw JSON.
String? noticePreviewLabel(String? content) {
  if (UndecryptableNotice.tryParse(content) != null) {
    return '\u{1F512} ${'chat_view.undecryptable_title'.tr()}'; // 🔒
  }
  if (UnsupportedEnvelopeNotice.tryParse(content) != null) {
    return '\u{2B06}\u{FE0F} ${'chat_view.unsupported_title'.tr()}'; // ⬆️
  }
  return null;
}
