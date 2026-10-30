// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/supabase/supabase_client_provider.dart';

/// Server-side abuse reporting (`reports` table + moderation RPCs, migration
/// 00060). Content-blind by design: a flag transmits only
/// `{message_id, chat_id, reason}` — never message content. Content reaches a
/// report solely via [revealMessage] (the accused self-reveals, or a recipient
/// once the corroboration gate opens), never through this insert path.
///
/// RLS forces `reporter_id = auth.uid()` and restricts flagging to chats the
/// reporter belongs to. Dedupe (one flag per reporter per subject) is enforced
/// by unique indexes — a duplicate throws and is swallowed as a no-op here.
class ReportsRepository {
  final SupabaseClient client;

  ReportsRepository(this.client);

  String get _uid {
    final id = client.auth.currentUser?.id;
    if (id == null) throw Exception('Cannot report: not authenticated');
    return id;
  }

  /// Flag a whole group by its (plaintext, server-visible) name/description.
  Future<void> reportGroup({
    required String chatId,
    required String reason,
  }) async {
    await _insert({
      'reporter_id': _uid,
      'subject_type': 'group',
      'reported_chat_id': chatId,
      'reason': reason,
    });
  }

  /// Flag a user — optionally pinned to a single received message
  /// ([messageId]). Only the ids + reason travel; no content.
  Future<void> reportUser({
    required String reportedUserId,
    required String chatId,
    required String reason,
    String? messageId,
  }) async {
    await _insert({
      'reporter_id': _uid,
      'subject_type': 'user',
      'reported_user_id': reportedUserId,
      'chat_id': chatId,
      'reason': reason,
      'message_id': ?messageId,
    });
  }

  Future<void> _insert(Map<String, dynamic> row) async {
    try {
      await client.from('reports').insert(row);
    } on PostgrestException catch (e) {
      // 23505 = duplicate (already flagged) → treat as success (idempotent).
      if (e.code == '23505') return;
      rethrow;
    }
  }

  /// The accused's self-reveal (or a recipient reveal once the gate is open):
  /// voluntarily attach the plaintext of a reported message + a signature that
  /// proves authorship. The server authorises the caller and refuses a recipient
  /// reveal until corroboration is reached.
  Future<void> revealMessage({
    required String reportId,
    required String text,
    String? sig,
    String? identityKey,
  }) async {
    await client.rpc<void>('reveal_reported_message', params: {
      'p_report_id': reportId,
      'p_text': text,
      'p_sig': sig,
      'p_identity_key': identityKey,
    });
  }

  /// Messages the current user sent that currently have an open report — the
  /// "you were reported, you may respond" signal. Reporter identity is never
  /// exposed.
  Future<List<ReportedMessage>> myReportedMessages() async {
    final rows = await client.rpc<List<dynamic>>('my_reported_messages');
    return rows
        .map((r) => ReportedMessage.fromJson(r as Map<String, dynamic>))
        .toList(growable: false);
  }
}

/// A message the current user sent that has been reported (the accused's view).
class ReportedMessage {
  final String reportId;
  final String messageId;
  final String? chatId;
  final String reason;

  const ReportedMessage({
    required this.reportId,
    required this.messageId,
    required this.chatId,
    required this.reason,
  });

  factory ReportedMessage.fromJson(Map<String, dynamic> json) => ReportedMessage(
        reportId: json['report_id'] as String,
        messageId: json['message_id'] as String,
        chatId: json['chat_id'] as String?,
        reason: json['reason'] as String,
      );
}

final reportsRepositoryProvider = Provider<ReportsRepository>((ref) {
  return ReportsRepository(ref.read(supabaseClientProvider));
});

/// The accused's open-report signal; refresh with `ref.invalidate`.
final myReportedMessagesProvider =
    FutureProvider.autoDispose<List<ReportedMessage>>((ref) async {
  return ref.read(reportsRepositoryProvider).myReportedMessages();
});
