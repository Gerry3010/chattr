// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/security/security_providers.dart';

/// Reciprocal read-receipt privacy switch (WhatsApp/Signal semantics).
///
/// When ON (the default), reading a message reports `read_at` to the sender and
/// the user sees others' read receipts. When OFF:
///  - the client stops calling the `mark_message_read` server RPC, so senders
///    never learn the message was read — their tick honestly caps at
///    "delivered" (we do NOT send a fake timestamp);
///  - reciprocally, the user's own outgoing bubbles never promote past
///    "delivered" either, hiding others' read state from them.
///
/// "Delivered/received" is unaffected in both directions: the message content is
/// already wiped server-side on *receive* (`mark_message_received` sets
/// `encrypted_content = ''`), so skipping the read RPC leaves nothing lingering
/// and delivery status keeps working. Local read state is still recorded on the
/// device (unread badge / unread divider) — it just never leaves the device.
final sendReadReceiptsProvider =
    StateNotifierProvider<ReadReceiptsController, bool>((ref) {
  return ReadReceiptsController(ref.read(secureStorageProvider));
});

class ReadReceiptsController extends StateNotifier<bool> {
  static const _storageKey = 'send_read_receipts_v1';

  final FlutterSecureStorage _storage;

  // Completes once the persisted value has been read. `state` defaults to `true`
  // for the synchronous DISPLAY path, but the SEND gate must await this (via
  // [resolvedValue]) — otherwise a cold start straight into a chat would fire a
  // read receipt using the stale default even when the user has receipts OFF.
  final Completer<void> _loaded = Completer<void>();

  // Default ON: an absent key means enabled — only an explicit 'false' disables
  // it (matches WhatsApp/Signal, and keeps "delivered" meaningful out of the box).
  ReadReceiptsController(this._storage) : super(true) {
    _init();
  }

  Future<void> _init() async {
    try {
      final raw = await _storage.read(key: _storageKey);
      if (mounted) state = raw != 'false';
    } finally {
      if (!_loaded.isCompleted) _loaded.complete();
    }
  }

  /// The persisted value, awaiting the initial secure-storage load first — use
  /// this on the SEND path so a cold-start read never leaks a read receipt when
  /// the user has them off. The synchronous [state] is fine for display.
  Future<bool> resolvedValue() async {
    await _loaded.future;
    return state;
  }

  Future<void> setEnabled(bool enabled) async {
    await _storage.write(key: _storageKey, value: enabled.toString());
    state = enabled;
  }
}
