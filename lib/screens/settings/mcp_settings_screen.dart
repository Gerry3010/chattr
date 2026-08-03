// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/mcp/mcp_token_model.dart';
import '../../features/mcp/mcp_tokens_controller.dart';
import '../../features/mcp/mcp_tokens_repository.dart';

/// Mint/list/revoke MCP agent tokens. A token authorizes an agent (e.g. an
/// AI coding assistant running chattr-mcp-server) to bind a chat it creates
/// to this user — that chat then appears in the hidden "MCP chats" row on
/// the home screen once this app auto-joins it. See
/// docs/MCP_AGENT_SERVER_PLAN.md and migration 00038_mcp_agent_chats.sql.
class McpSettingsScreen extends ConsumerWidget {
  const McpSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokensAsync = ref.watch(mcpTokensProvider);

    return Scaffold(
      appBar: AppBar(title: Text('settings.mcp.title'.tr())),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'settings.mcp.intro'.tr(),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
          Expanded(
            child: tokensAsync.when(
              data: (tokens) => tokens.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'settings.mcp.empty'.tr(),
                          textAlign: TextAlign.center,
                          style: Theme.of(context)
                              .textTheme
                              .bodyLarge
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: tokens.length,
                      itemBuilder: (context, index) =>
                          _TokenTile(token: tokens[index]),
                    ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (err, _) => Center(
                child: Text('common.error'.tr(args: [err.toString()])),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton.icon(
              key: const ValueKey('mcp_mint_token_button'),
              onPressed: () => _mintToken(context, ref),
              icon: const Icon(Icons.add),
              label: Text('settings.mcp.mint'.tr()),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _mintToken(BuildContext context, WidgetRef ref) async {
    final labelController = TextEditingController();
    final proceed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('settings.mcp.mint_dialog_title'.tr()),
        content: TextField(
          controller: labelController,
          autofocus: true,
          decoration: InputDecoration(
            labelText: 'settings.mcp.label_hint'.tr(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text('common.cancel'.tr()),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text('settings.mcp.mint'.tr()),
          ),
        ],
      ),
    );
    if (proceed != true || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      final secret = await ref.read(mcpTokensRepositoryProvider).mintToken(
            label: labelController.text.trim().isEmpty
                ? null
                : labelController.text.trim(),
          );
      ref.invalidate(mcpTokensProvider);
      if (!context.mounted) return;
      await _showSecretOnce(context, secret);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('common.error'.tr(args: ['$e']))),
      );
    }
  }

  Future<void> _showSecretOnce(BuildContext context, String secret) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: Text('settings.mcp.secret_title'.tr()),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('settings.mcp.secret_warning'.tr()),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(dialogContext).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                secret,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: secret));
              ScaffoldMessenger.of(dialogContext).showSnackBar(
                SnackBar(content: Text('settings.mcp.copied'.tr())),
              );
            },
            icon: const Icon(Icons.copy),
            label: Text('settings.mcp.copy'.tr()),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text('settings.mcp.secret_done'.tr()),
          ),
        ],
      ),
    );
  }
}

class _TokenTile extends ConsumerWidget {
  final McpTokenInfo token;

  const _TokenTile({required this.token});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dateFormat = DateFormat.yMMMd(context.locale.toString()).add_Hm();
    return ListTile(
      leading: Icon(
        Icons.smart_toy_outlined,
        color: token.isRevoked
            ? Theme.of(context).colorScheme.outline
            : Theme.of(context).colorScheme.primary,
      ),
      title: Text(token.label ?? 'settings.mcp.unnamed_token'.tr()),
      subtitle: Text(
        token.isRevoked
            ? 'settings.mcp.revoked_on'
                .tr(args: [dateFormat.format(token.revokedAt!.toLocal())])
            : 'settings.mcp.created_on'
                .tr(args: [dateFormat.format(token.createdAt.toLocal())]),
      ),
      trailing: token.isRevoked
          ? null
          : TextButton(
              onPressed: () => _revoke(context, ref),
              child: Text('settings.mcp.revoke'.tr()),
            ),
    );
  }

  Future<void> _revoke(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('settings.mcp.revoke_confirm_title'.tr()),
        content: Text('settings.mcp.revoke_confirm_body'.tr()),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text('common.cancel'.tr()),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text('settings.mcp.revoke'.tr()),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(mcpTokensRepositoryProvider).revokeToken(token.id);
      ref.invalidate(mcpTokensProvider);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('common.error'.tr(args: ['$e']))),
      );
    }
  }
}
