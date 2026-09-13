// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../agents/main_agent_store.dart';
import '../messages/message_model.dart';
import '../messages/messages_controller.dart';
import 'summary_envelope.dart';

/// Ephemeral state machine behind the summary sheet.
///
/// The protocol ([SummaryRequest]/[SummaryReply], summary_envelope.dart) gives
/// no delivery guarantee: an answer only comes if an agent session happens to
/// be running. So the state machine's job is mostly honesty — after
/// [timeout] it says "no answer" instead of spinning, and if the answer
/// arrives late anyway, it still flips to [SummaryPhase.done] (a late summary
/// is a summary, not an error).
enum SummaryPhase { idle, waiting, done, timeout, failed }

class SummaryUiState {
  final SummaryPhase phase;

  /// Message id of the in-flight request; replies must match it (`for`).
  final String? requestId;

  /// The agent's answer, when [phase] is [SummaryPhase.done].
  final String? text;

  const SummaryUiState._(this.phase, {this.requestId, this.text});

  static const idle = SummaryUiState._(SummaryPhase.idle);
  const SummaryUiState.waiting(String requestId)
      : this._(SummaryPhase.waiting, requestId: requestId);
  const SummaryUiState.done(String requestId, String text)
      : this._(SummaryPhase.done, requestId: requestId, text: text);
  const SummaryUiState.timeout(String requestId)
      : this._(SummaryPhase.timeout, requestId: requestId);
  static const failed = SummaryUiState._(SummaryPhase.failed);
}

final summaryControllerProvider = StateNotifierProvider.autoDispose
    .family<SummaryController, SummaryUiState, String>((ref, chatId) {
  final controller = SummaryController(ref, chatId);
  // The reply travels the ordinary message pipeline and lands in the messages
  // state (the chat view filters it from display; the data layer keeps it).
  // Listening here is what connects "a message arrived" to "the sheet shows
  // the summary".
  ref.listen<List<MessageInterface>>(
    messagesControllerProvider(chatId),
    (_, messages) => controller.scanForReply(messages),
  );
  return controller;
});

class SummaryController extends StateNotifier<SummaryUiState> {
  /// How long the sheet waits before admitting no agent answered. Long enough
  /// for a sleeping agent session to wake, fetch, summarise and send; short
  /// enough that "nothing is running" doesn't look like loading.
  static const timeout = Duration(seconds: 60);

  final Ref ref;
  final String chatId;
  Timer? _timer;

  SummaryController(this.ref, this.chatId) : super(SummaryUiState.idle);

  /// Sends a summary request addressed to the chat's main agent (if one is
  /// chosen — otherwise unaddressed, meaning any agent may answer).
  Future<void> request({
    required SummaryScope scope,
    DateTime? since,
    String? hint,
  }) async {
    _timer?.cancel();
    try {
      final envelope = SummaryRequest(
        scope: scope,
        since: since,
        hint: hint,
        agent: ref.read(mainAgentProvider(chatId)),
      ).encode();

      final requestId = await ref
          .read(messagesControllerProvider(chatId).notifier)
          .sendMachineryMessage(envelope, messageType: 'summary');
      if (!mounted) return;

      state = SummaryUiState.waiting(requestId);
      _timer = Timer(timeout, () {
        if (mounted && state.phase == SummaryPhase.waiting) {
          state = SummaryUiState.timeout(requestId);
        }
      });
    } catch (_) {
      if (mounted) state = SummaryUiState.failed;
    }
  }

  /// Called on every messages-state change: looks for a [SummaryReply]
  /// answering the in-flight request. Also accepts a reply that arrives after
  /// the timeout already fired.
  void scanForReply(List<MessageInterface> messages) {
    final requestId = state.requestId;
    if (requestId == null || state.phase == SummaryPhase.done) return;

    // Newest first — the reply is virtually always at the tail.
    for (final m in messages.reversed) {
      final reply = SummaryReply.tryParse(m.decryptedContent);
      if (reply != null && reply.forRequestId == requestId) {
        _timer?.cancel();
        state = SummaryUiState.done(requestId, reply.text);
        return;
      }
    }
  }

  /// Back to the scope-selection screen (keeps nothing — ephemeral by design).
  void reset() {
    _timer?.cancel();
    state = SummaryUiState.idle;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
