// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../features/chat_view/chat_view_controller.dart';
import '../../../features/summary/summary_controller.dart';
import '../../../features/summary/summary_envelope.dart';
import 'safe_markdown.dart';

/// The chat-summary sheet — MCP chats only (the caller gates on `Chat.isMcp`;
/// in a normal chat the other side never consented to a model reading along).
///
/// Ephemeral by design: the summary lives in this sheet and nowhere else — no
/// bubble, no history. Closing the sheet discards everything.
Future<void> showSummarySheet({
  required BuildContext context,
  required String chatId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => SafeArea(child: _SummarySheet(chatId: chatId)),
  );
}

class _SummarySheet extends HookConsumerWidget {
  final String chatId;

  const _SummarySheet({required this.chatId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(summaryControllerProvider(chatId));
    final maxHeight = MediaQuery.of(context).size.height * 0.75;

    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Padding(
          // Keep the hint field above the keyboard.
          padding: EdgeInsets.only(
            left: 24,
            right: 24,
            bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
          ),
          child: switch (state.phase) {
            SummaryPhase.idle => _ScopePicker(chatId: chatId),
            SummaryPhase.waiting => const _Waiting(),
            SummaryPhase.done => _Result(chatId: chatId, text: state.text ?? ''),
            SummaryPhase.timeout => _NoAnswer(chatId: chatId),
            SummaryPhase.failed => _Failed(chatId: chatId),
          },
        ),
      ),
    );
  }
}

/// Scope + optional hint, then send. "Unread" is the default — it is what the
/// feature exists for ("what did I miss without scrolling").
class _ScopePicker extends HookConsumerWidget {
  final String chatId;

  const _ScopePicker({required this.chatId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = useState(SummaryScope.unread);
    final since = useState<DateTime?>(null);
    final hintController = useTextEditingController();

    Future<void> submit() async {
      DateTime? resolvedSince;
      if (scope.value == SummaryScope.since) {
        resolvedSince = since.value;
        if (resolvedSince == null) return; // no date picked yet
      } else if (scope.value == SummaryScope.unread) {
        // The boundary snapshot from when the chat was opened — by now the
        // messages are already marked read, so this is the only place that
        // still knows where "unread" began.
        resolvedSince =
            ref.read(chatViewControllerProvider(chatId).notifier).unreadBoundary;
      }
      final hint = hintController.text.trim();
      await ref.read(summaryControllerProvider(chatId).notifier).request(
            scope: scope.value,
            since: resolvedSince,
            hint: hint.isEmpty ? null : hint,
          );
    }

    Future<void> pickSince() async {
      final now = DateTime.now();
      final date = await showDatePicker(
        context: context,
        initialDate: since.value ?? now,
        firstDate: now.subtract(const Duration(days: 365)),
        lastDate: now,
      );
      if (date == null) return;
      since.value = date;
      scope.value = SummaryScope.since;
    }

    final locale = context.locale.toString();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'summary.title'.tr(),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
        Text(
          'summary.subtitle'.tr(),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        SegmentedButton<SummaryScope>(
          segments: [
            ButtonSegment(
              value: SummaryScope.unread,
              label: Text('summary.scope_unread'.tr()),
            ),
            ButtonSegment(
              value: SummaryScope.all,
              label: Text('summary.scope_all'.tr()),
            ),
            ButtonSegment(
              value: SummaryScope.since,
              label: Text(
                since.value == null
                    ? 'summary.scope_since'.tr()
                    : DateFormat.yMd(locale).format(since.value!),
              ),
            ),
          ],
          selected: {scope.value},
          onSelectionChanged: (selection) {
            final chosen = selection.first;
            if (chosen == SummaryScope.since) {
              pickSince();
            } else {
              scope.value = chosen;
            }
          },
        ),
        const SizedBox(height: 16),
        TextField(
          controller: hintController,
          maxLength: 200,
          decoration: InputDecoration(
            labelText: 'summary.hint_label'.tr(),
            border: const OutlineInputBorder(),
            counterText: '',
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: submit,
          icon: const Icon(Icons.auto_awesome),
          label: Text('summary.request_button'.tr()),
        ),
      ],
    );
  }
}

class _Waiting extends StatelessWidget {
  const _Waiting();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 16),
        const CircularProgressIndicator(),
        const SizedBox(height: 16),
        Text('summary.waiting'.tr(), textAlign: TextAlign.center),
        const SizedBox(height: 16),
      ],
    );
  }
}

class _Result extends ConsumerWidget {
  final String chatId;
  final String text;

  const _Result({required this.chatId, required this.text});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'summary.result_title'.tr(),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 12),
        Flexible(
          child: SingleChildScrollView(
            child: SafeMarkdown(
              data: text,
              textColor: scheme.onSurface,
              linkColor: scheme.primary,
              fontSize: 15,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            TextButton(
              onPressed: () =>
                  ref.read(summaryControllerProvider(chatId).notifier).reset(),
              child: Text('summary.new_request'.tr()),
            ),
            const Spacer(),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: Text('summary.close'.tr()),
            ),
          ],
        ),
      ],
    );
  }
}

/// The honest state: no agent session was running, nobody answered. The
/// protocol cannot guarantee delivery (the agent is not a server), so this is
/// a normal outcome, not an error.
class _NoAnswer extends ConsumerWidget {
  final String chatId;

  const _NoAnswer({required this.chatId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _Notice(
      icon: Icons.hourglass_empty,
      title: 'summary.no_answer_title'.tr(),
      body: 'summary.no_answer_body'.tr(),
      chatId: chatId,
    );
  }
}

class _Failed extends ConsumerWidget {
  final String chatId;

  const _Failed({required this.chatId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _Notice(
      icon: Icons.error_outline,
      title: 'summary.failed_title'.tr(),
      body: 'summary.failed_body'.tr(),
      chatId: chatId,
    );
  }
}

class _Notice extends ConsumerWidget {
  final IconData icon;
  final String title;
  final String body;
  final String chatId;

  const _Notice({
    required this.icon,
    required this.title,
    required this.body,
    required this.chatId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(icon, size: 40, color: Theme.of(context).colorScheme.outline),
        const SizedBox(height: 12),
        Text(title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(body,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: () =>
              ref.read(summaryControllerProvider(chatId).notifier).reset(),
          child: Text('summary.retry'.tr()),
        ),
      ],
    );
  }
}
