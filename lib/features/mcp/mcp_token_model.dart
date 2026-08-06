// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Metadata for an MCP agent token (never the secret itself — the server
/// only stores its hash, see migration 00038_mcp_agent_chats.sql).
class McpTokenInfo {
  final String id;
  final String? label;
  final DateTime createdAt;
  final DateTime? revokedAt;

  const McpTokenInfo({
    required this.id,
    this.label,
    required this.createdAt,
    this.revokedAt,
  });

  bool get isRevoked => revokedAt != null;

  factory McpTokenInfo.fromJson(Map<String, dynamic> json) => McpTokenInfo(
        id: json['id'] as String,
        label: json['label'] as String?,
        createdAt: DateTime.parse(json['created_at'] as String),
        revokedAt: json['revoked_at'] != null
            ? DateTime.parse(json['revoked_at'] as String)
            : null,
      );
}
