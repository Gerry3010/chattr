// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Copyright (C) 2026 Gerald Hofbauer <info@geraldhofbauer.net>
// AGPLv3 — see <https://www.gnu.org/licenses/>.
//
// MCP tool registrations (v1) — see docs/MCP_AGENT_SERVER_PLAN.md section 4.
// Deliberately thin: each tool is a primitive; policy (e.g. "auto-approve
// *-claude usernames, escalate the rest to Gerry") lives in the calling
// agent's own reasoning over chattr_pending's output, not hard-coded here.

import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { z } from 'zod';
import { getClient, initIdentity, currentUserId, requireUserId, getUsername } from './supabase.js';
import { ensureProjectChat, resolveChatId, joinChat, listPending, approvePending, getChatInfo } from './chats.js';
import { sendMessage, fetchMessages, getHistory, waitForMessages } from './messages.js';
import { fetchMedia } from './media.js';
import { readRegistry, readGlobalChatId } from './registry.js';
import { config } from './config.js';

type ToolResult = { content: Array<{ type: 'text'; text: string }>; isError?: boolean };

function ok(data: unknown): ToolResult {
  return { content: [{ type: 'text', text: JSON.stringify(data, null, 2) }] };
}

function fail(err: unknown): ToolResult {
  const text = err instanceof Error ? err.message : String(err);
  return { content: [{ type: 'text', text }], isError: true };
}

async function guarded(fn: () => Promise<unknown>): Promise<ToolResult> {
  try {
    return ok(await fn());
  } catch (err) {
    return fail(err);
  }
}

const projectOrChat = {
  project: z
    .string()
    .optional()
    .describe(
      'Project name — resolves the chat via .chattr-agents.json in repoPath, falling back to the global registry (~/.claude/chattr-agents.json) so a project is reachable by name regardless of cwd',
    ),
  chat_id: z.string().optional().describe('Explicit chat id — takes precedence over project'),
  repo_path: z.string().optional().describe('Repo root containing .chattr-agents.json (defaults to cwd) — only relevant if project is a repo-local one'),
};

function repoPathOf(args: { repo_path?: string }): string {
  return args.repo_path ?? process.cwd();
}

export function createServer(): McpServer {
  const server = new McpServer(
    { name: 'chattr-mcp-server', version: '0.1.0' },
    { capabilities: { tools: {} } },
  );

  server.registerTool(
    'chattr_status',
    {
      description:
        'Who am I, is the session valid, and which project chat (if any) is registered for the given repo / globally. Call this first.',
      inputSchema: { repo_path: z.string().optional(), project: z.string().optional() },
    },
    (args) =>
      guarded(async () => {
        const userId = await currentUserId();
        const repoPath = repoPathOf(args);
        const repoRegistry = readRegistry(repoPath);
        return {
          initialized: userId !== null,
          userId,
          username: userId ? await getUsername(userId) : null,
          profile: config.profile,
          registeredProjectInRepo: repoRegistry,
          globalChatId: args.project ? readGlobalChatId(args.project) : undefined,
        };
      }),
  );

  server.registerTool(
    'chattr_init',
    {
      description:
        'One-time setup: create an anonymous Chattr account with the given username (convention: suffix "-claude", e.g. "linux-claude"). No-op if already initialized — NEVER call this again after the first successful run, it would orphan every chat this identity already joined.',
      inputSchema: { username: z.string().min(1) },
    },
    ({ username }) => guarded(() => initIdentity(username)),
  );

  server.registerTool(
    'chattr_ensure_project_chat',
    {
      description:
        'Finds or creates the group chat "agents:<project>", binds it to the human owner via MCP_TOKEN, and records it in .chattr-agents.json at repo_path. Idempotent. Requires chattr_init and MCP_TOKEN to be set.',
      inputSchema: {
        project: z.string().min(1),
        repo_path: z.string().optional(),
      },
    },
    (args) =>
      guarded(async () => {
        const client = getClient();
        const userId = await requireUserId();
        return ensureProjectChat(client, userId, args.project, repoPathOf(args));
      }),
  );

  server.registerTool(
    'chattr_join',
    {
      description:
        'Requests to join an existing chat (headless — generates a per-chat keypair and inserts a pending_chat_members row). Needs an admin to chattr_approve it before messages can be sent/received.',
      inputSchema: projectOrChat,
    },
    (args) =>
      guarded(async () => {
        const client = getClient();
        const userId = await requireUserId();
        const chatId = resolveChatId(args.project, args.chat_id, repoPathOf(args));
        return joinChat(client, userId, chatId);
      }),
  );

  server.registerTool(
    'chattr_pending',
    {
      description:
        'Lists pending join requests for a chat this agent administers (id + username + requested-at). Apply your own approve policy (e.g. auto-approve *-claude usernames and the chat\'s mcp_owner_id, escalate anyone else to the human) then call chattr_approve.',
      inputSchema: projectOrChat,
    },
    (args) =>
      guarded(async () => {
        const client = getClient();
        const chatId = resolveChatId(args.project, args.chat_id, repoPathOf(args));
        const [pending, chat] = await Promise.all([listPending(client, chatId), getChatInfo(client, chatId)]);
        return { chatId, mcpOwnerId: chat.mcp_owner_id, pending };
      }),
  );

  server.registerTool(
    'chattr_approve',
    {
      description: 'Approves a pending join request by user id — moves them from pending into chat_members. Admin-only (enforced by RLS).',
      inputSchema: { ...projectOrChat, user_id: z.string().min(1) },
    },
    (args) =>
      guarded(async () => {
        const client = getClient();
        const chatId = resolveChatId(args.project, args.chat_id, repoPathOf(args));
        await approvePending(client, chatId, args.user_id);
        return { approved: args.user_id, chatId };
      }),
  );

  server.registerTool(
    'chattr_send',
    {
      description: 'Sends a text message to every other member of the chat (encrypted per-recipient). No media/reactions/edits in v1.',
      inputSchema: { ...projectOrChat, text: z.string().min(1) },
    },
    (args) =>
      guarded(async () => {
        const client = getClient();
        const userId = await requireUserId();
        const chatId = resolveChatId(args.project, args.chat_id, repoPathOf(args));
        return sendMessage(client, userId, chatId, args.text);
      }),
  );

  server.registerTool(
    'chattr_fetch',
    {
      description:
        'Fetches and decrypts new messages since the last fetch, persists them locally, and clears server ciphertext (mark_message_read). Returns an empty list if there is nothing new.',
      inputSchema: projectOrChat,
    },
    (args) =>
      guarded(async () => {
        const client = getClient();
        const userId = await requireUserId();
        const chatId = resolveChatId(args.project, args.chat_id, repoPathOf(args));
        return fetchMessages(client, userId, chatId);
      }),
  );

  server.registerTool(
    'chattr_history',
    {
      description: 'Reads message history from the local store (the server has nothing left once messages are read).',
      inputSchema: { ...projectOrChat, limit: z.number().int().min(1).max(500).default(50) },
    },
    (args) =>
      guarded(async () => {
        const chatId = resolveChatId(args.project, args.chat_id, repoPathOf(args));
        return getHistory(chatId, args.limit);
      }),
  );

  server.registerTool(
    'chattr_wait',
    {
      description:
        'Blocks via Realtime (the same broadcast channel the app uses) until a new message arrives or timeout_s elapses (max ~300s), then returns it — near-instant, not a polling loop. Lower latency than a cron-based chattr_fetch loop for an active collaboration session.',
      inputSchema: { ...projectOrChat, timeout_s: z.number().int().min(1).max(300).default(270) },
    },
    (args) =>
      guarded(async () => {
        const client = getClient();
        const userId = await requireUserId();
        const chatId = resolveChatId(args.project, args.chat_id, repoPathOf(args));
        return waitForMessages(client, userId, chatId, args.timeout_s);
      }),
  );

  server.registerTool(
    'chattr_fetch_media',
    {
      description:
        "Downloads and decrypts a Chattr media blob (the encrypted image/file a `_chattr_media` message points at) and saves the plaintext to a local file so it can be viewed/read. Pass `path` and `key` verbatim from the media message JSON (plus `compression` if that field is present). Returns the saved file path. The agent must be a member of the chat the media belongs to (storage RLS).",
      inputSchema: {
        path: z
          .string()
          .describe('Bucket-relative object path from the message JSON (<chatId>/<messageId>/<name>.enc)'),
        key: z.string().describe('base64 AES-256 key from the message JSON'),
        compression: z
          .string()
          .optional()
          .describe("Pass the JSON's `compression` value ('gzip'); omit if the field is absent"),
        name: z.string().optional().describe('Original filename (used for the saved file name)'),
        mime: z.string().optional(),
        size: z.number().int().optional().describe('Original plaintext size, for an integrity check'),
        out_path: z.string().optional().describe('Absolute path to save the decrypted file (default: OS temp dir)'),
      },
    },
    (args) =>
      guarded(async () => {
        await requireUserId();
        return fetchMedia(args);
      }),
  );

  return server;
}
