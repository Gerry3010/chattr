// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Web plays media from in-memory Blob object URLs, never touching disk, so
/// there is no decrypted-media temp-cache to purge (audit M8). No-op.
Future<void> purgeMediaCache() async {}
