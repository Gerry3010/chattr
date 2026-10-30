// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatview/chatview.dart' as chatview;
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import '../../core/network/network_errors.dart';
import '../../core/security/keys_not_ready_exception.dart';

/// Where the sender's own message stands on its way to the server (CHAT-66).
///
/// Local only, never sent: the server either has a message or it does not.
/// Null on every message the server has and on every incoming one, so rows
/// stored before this field existed read as sent.
enum LocalSendState {
  /// On screen and on the device, the send is running.
  pending,

  /// The send did not get through. Stays until resent or discarded, across
  /// restarts (Gerry, 2026-10-29).
  failed,
}

/// Why a send failed. Decides what the "Nicht gesendet" sheet says, not what
/// it offers: a retry is always possible.
enum SendFailure {
  /// No network, or the server did not answer.
  network,

  /// The other side has not published its chat key yet (just added).
  keysNotReady,

  /// The server answered and said no (not a member any more, blocked, …).
  rejected,
}

/// Keys in chatview's untyped `Message.update` bag, next to [sigStatusKey].
const String sendStateKey = 'send_state';
const String sendFailureKey = 'send_failure';

LocalSendState? sendStateOf(chatview.Message message) =>
    _byName(LocalSendState.values, message.update?[sendStateKey]);

SendFailure? sendFailureOf(chatview.Message message) =>
    _byName(SendFailure.values, message.update?[sendFailureKey]);

T? _byName<T extends Enum>(List<T> values, Object? raw) {
  for (final v in values) {
    if (v.name == raw) return v;
  }
  return null;
}

SendFailure classifySendFailure(Object error) {
  if (error is KeysNotReadyException) return SendFailure.keysNotReady;
  if (isNetworkError(error)) return SendFailure.network;
  return SendFailure.rejected;
}

/// A resend of a message whose earlier attempt did reach the server, only the
/// answer got lost. The id is minted on the device and is the primary key
/// together with the recipient, so the second insert hits 23505 — which means
/// the message is there.
bool isAlreadyOnServer(Object error) =>
    error is PostgrestException && error.code == '23505';
