// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

/// The plaintext of a call signal — what travels INSIDE the sealed envelope.
///
/// Three kinds only: `invite` (carries the caller's SDP offer), `accept`
/// (the callee's SDP answer) and `end` (with a reason). No trickled ICE: each
/// side gathers its candidates first and ships them inside its SDP, so a call
/// costs three sealed signals instead of dozens, and there is no candidate
/// that can arrive before the description it belongs to.
library;

import 'dart:convert';

/// Marks a plaintext as a call signal. Part of the signed bytes, so a sealed
/// signal can never be passed off as something else that decrypts.
const String callSignalKind = 'chattr-call-1';

/// How far a signal's own timestamp may stray from this device's clock.
///
/// The server forwards opaque envelopes and cannot forge one, but it could
/// REPLAY an old invite and make a phone ring for a call that ended hours
/// ago. Two minutes is generous for clock skew and short for a replay.
const Duration callSignalMaxAge = Duration(minutes: 2);

/// `restart`/`restarted` (ICE restart after a network change) came later. An
/// older app drops a type it does not know (see [CallSignal.tryDecode]), so
/// the call simply ends there as it always did.
enum CallSignalType { invite, accept, end, restart, restarted }

class CallSignal {
  const CallSignal({
    required this.type,
    required this.callId,
    required this.sentAt,
    this.sdp,
    this.reason,
    this.seq,
  });

  final CallSignalType type;
  final String callId;
  final DateTime sentAt;

  /// Offer (invite) or answer (accept), with all ICE candidates inlined.
  final String? sdp;

  /// Wire reason of an `end` (see `CallEndReason.wire`).
  final String? reason;

  /// Round of a `restart`/`restarted`. A round only ever counts up, so a
  /// replayed older restart cannot drag the connection back to a dead path.
  final int? seq;

  String encode() => jsonEncode({
        'k': callSignalKind,
        't': type.name,
        'id': callId,
        'ts': sentAt.toUtc().millisecondsSinceEpoch,
        if (sdp != null) 'sdp': sdp,
        if (reason != null) 'r': reason,
        if (seq != null) 'n': seq,
      });

  /// Parses a decrypted plaintext. Returns null for anything that is not a
  /// well-formed call signal — a broken signal is dropped, never half-read.
  static CallSignal? tryDecode(String plaintext) {
    try {
      final m = jsonDecode(plaintext);
      if (m is! Map<String, dynamic>) return null;
      if (m['k'] != callSignalKind) return null;
      final type = CallSignalType.values
          .where((t) => t.name == m['t'])
          .firstOrNull;
      final id = m['id'];
      final ts = m['ts'];
      if (type == null || id is! String || id.isEmpty || ts is! int) {
        return null;
      }
      final sdp = m['sdp'];
      final reason = m['r'];
      final seq = m['n'];
      final isRestart = type == CallSignalType.restart ||
          type == CallSignalType.restarted;
      if (isRestart && seq is! int) return null;
      // An invite or accept without a description is useless; refuse it here
      // instead of failing deep inside WebRTC.
      if (type != CallSignalType.end && (sdp is! String || sdp.isEmpty)) {
        return null;
      }
      return CallSignal(
        type: type,
        callId: id,
        sentAt: DateTime.fromMillisecondsSinceEpoch(ts, isUtc: true),
        sdp: sdp is String ? sdp : null,
        reason: reason is String ? reason : null,
        seq: seq is int ? seq : null,
      );
    } catch (_) {
      return null;
    }
  }

  /// Whether [sentAt] is close enough to [now] to be acted on.
  bool isFresh(DateTime now) =>
      now.toUtc().difference(sentAt).abs() <= callSignalMaxAge;
}

/// The chat id the signal's AAD and signature are bound to.
///
/// Prefixed, so the bytes a call signal is signed over can never equal those
/// of a chat message in the same chat: a sealed signal re-inserted as a
/// message row would fail to open, and the other way round.
String callSignalContextChatId(String chatId) => 'call:$chatId';
