// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Unit tests for the MCP auto-join reconciler's enable gate
// (McpAutoJoinController.hasActiveToken).
//
// Regression context: the gate used to be a synchronous `mcpEnabledProvider`
// that read the async `mcpTokensProvider` via maybeWhen(orElse: false). On
// cold start the token list was still AsyncLoading, so the gate returned false
// and reconcile() bailed on every run — the owner's app never discovered/
// joined chats bound to its MCP token. reconcile() now awaits the token future
// and feeds the resolved list to this pure predicate. These tests lock the
// predicate's rules (revoked tokens don't count as "enabled").

import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/features/mcp/mcp_auto_join_controller.dart';
import 'package:chattr/features/mcp/mcp_token_model.dart';

void main() {
  final createdAt = DateTime.utc(2026, 7, 12, 12);

  McpTokenInfo token({required bool revoked}) => McpTokenInfo(
        id: revoked ? 'revoked' : 'active',
        createdAt: createdAt,
        revokedAt: revoked ? createdAt.add(const Duration(hours: 1)) : null,
      );

  group('McpAutoJoinController.hasActiveToken', () {
    test('no tokens -> disabled', () {
      expect(McpAutoJoinController.hasActiveToken(const []), isFalse);
    });

    test('one active token -> enabled', () {
      expect(
        McpAutoJoinController.hasActiveToken([token(revoked: false)]),
        isTrue,
      );
    });

    test('only revoked tokens -> disabled', () {
      expect(
        McpAutoJoinController.hasActiveToken([
          token(revoked: true),
          token(revoked: true),
        ]),
        isFalse,
      );
    });

    test('a revoked token alongside an active one -> enabled', () {
      expect(
        McpAutoJoinController.hasActiveToken([
          token(revoked: true),
          token(revoked: false),
        ]),
        isTrue,
      );
    });
  });
}
