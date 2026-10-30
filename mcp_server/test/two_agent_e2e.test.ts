// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Copyright (C) 2026 Gerald Hofbauer <info@geraldhofbauer.net>
// AGPLv3 — see <https://www.gnu.org/licenses/>.
//
// Full two-agent round trip against a LOCAL Supabase instance, through the
// real stdio MCP transport (spawns the built server twice, exactly like
// Claude Code would). Requires `supabase start` — skips with a clear
// message if the local API isn't reachable, matching
// test/e2e_two_users_test.dart's pattern on the Flutter side.
//
// Flow: mint an owner token (direct REST, simulating the Chattr app) ->
// agent "linux-claude" ensure_project_chat (create + bind) -> agent
// "mac-claude" chattr_join -> linux-claude chattr_approve -> mac-claude
// chattr_send -> linux-claude chattr_fetch -> linux-claude chattr_send
// (reply) -> mac-claude chattr_fetch -> chattr_history on both sides.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { McpStdioClient } from './mcp_stdio_client.js';

const SUPABASE_URL = process.env.SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SUPABASE_ANON_KEY =
  process.env.SUPABASE_ANON_KEY ??
  // Standard Supabase CLI local demo anon key (public, same one printed by `supabase status`).
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0';

async function localSupabaseReachable(): Promise<boolean> {
  try {
    const res = await fetch(`${SUPABASE_URL}/auth/v1/health`, { signal: AbortSignal.timeout(2000) });
    return res.ok;
  } catch {
    return false;
  }
}

async function signUpAnon(): Promise<{ userId: string; accessToken: string }> {
  const res = await fetch(`${SUPABASE_URL}/auth/v1/signup`, {
    method: 'POST',
    headers: { apikey: SUPABASE_ANON_KEY, 'Content-Type': 'application/json' },
    body: '{}',
  });
  const data = await res.json();
  if (!res.ok || !data.access_token) {
    throw new Error(`signup failed: ${JSON.stringify(data)}`);
  }
  return { userId: data.user.id, accessToken: data.access_token };
}

async function createProfile(userId: string, username: string, accessToken: string): Promise<void> {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/profiles`, {
    method: 'POST',
    headers: {
      apikey: SUPABASE_ANON_KEY,
      Authorization: `Bearer ${accessToken}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ id: userId, username }),
  });
  if (!res.ok) throw new Error(`createProfile failed: ${await res.text()}`);
}

async function mintOwnerToken(accessToken: string): Promise<string> {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/mint_mcp_token`, {
    method: 'POST',
    headers: {
      apikey: SUPABASE_ANON_KEY,
      Authorization: `Bearer ${accessToken}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ p_label: 'two-agent-e2e-test' }),
  });
  const data = await res.json();
  if (!res.ok) throw new Error(`mint_mcp_token failed: ${JSON.stringify(data)}`);
  return data as string;
}

test('two-agent E2E: ensure_project_chat -> join -> approve -> send -> fetch (real stdio transport, local Supabase)', async (t) => {
  if (!(await localSupabaseReachable())) {
    t.skip('local Supabase not reachable at ' + SUPABASE_URL + ' — run `supabase start` first');
    return;
  }

  const owner = await signUpAnon();
  await createProfile(owner.userId, 'e2e-owner', owner.accessToken);
  const ownerToken = await mintOwnerToken(owner.accessToken);

  const stateDir1 = mkdtempSync(path.join(tmpdir(), 'chattr-agent-linux-'));
  const stateDir2 = mkdtempSync(path.join(tmpdir(), 'chattr-agent-mac-'));
  const repoDir = mkdtempSync(path.join(tmpdir(), 'chattr-e2e-repo-'));
  // Isolate from the real ~/.claude/chattr-agents.json — tests must never write there.
  const globalRegistryPath = path.join(repoDir, 'global-registry.json');

  const linux = new McpStdioClient(
    {
      SUPABASE_URL,
      SUPABASE_ANON_KEY,
      MCP_TOKEN: ownerToken,
      CHATTR_AGENT_STATE_DIR: stateDir1,
      CHATTR_GLOBAL_REGISTRY_PATH: globalRegistryPath,
    },
    'linux-claude',
  );
  const mac = new McpStdioClient(
    {
      SUPABASE_URL,
      SUPABASE_ANON_KEY,
      CHATTR_AGENT_STATE_DIR: stateDir2,
      CHATTR_GLOBAL_REGISTRY_PATH: globalRegistryPath,
    },
    'mac-claude',
  );

  try {
    await linux.initialize();
    await mac.initialize();

    const linuxInit = await linux.callTool('chattr_init', { username: 'linux-claude-e2e' });
    assert.equal(linuxInit.alreadyInitialized, false);
    const macInit = await mac.callTool('chattr_init', { username: 'mac-claude-e2e' });
    assert.equal(macInit.alreadyInitialized, false);
    assert.notEqual(linuxInit.userId, macInit.userId);

    // linux-claude creates + binds the project chat.
    const ensured = await linux.callTool('chattr_ensure_project_chat', {
      project: 'e2e-test',
      repo_path: repoDir,
    });
    assert.equal(ensured.created, true);
    assert.equal(ensured.ownerId, owner.userId);
    const chatId = ensured.chatId;

    // Idempotency: calling it again returns the same chat without re-creating.
    const ensuredAgain = await linux.callTool('chattr_ensure_project_chat', {
      project: 'e2e-test',
      repo_path: repoDir,
    });
    assert.equal(ensuredAgain.chatId, chatId);
    assert.equal(ensuredAgain.created, false);

    // mac-claude requests to join by chat_id (no shared registry file needed for this test).
    const joinResult = await mac.callTool('chattr_join', { chat_id: chatId });
    assert.equal(joinResult.status, 'requested');

    // linux-claude (admin) sees the pending request and approves it.
    const pending = await linux.callTool<{ pending: Array<{ userId: string; username: string | null }> }>(
      'chattr_pending',
      { chat_id: chatId },
    );
    assert.equal(pending.pending.length, 1);
    assert.equal(pending.pending[0].username, 'mac-claude-e2e');
    await linux.callTool('chattr_approve', { chat_id: chatId, user_id: pending.pending[0].userId });

    // mac-claude -> linux-claude
    const sent1 = await mac.callTool('chattr_send', { chat_id: chatId, text: 'TASK: verify build 1.1.7+10' });
    assert.ok(sent1.messageId);

    const fetched1 = await linux.callTool<Array<{ text: string; senderName: string | null }>>('chattr_fetch', {
      chat_id: chatId,
    });
    assert.equal(fetched1.length, 1);
    assert.equal(fetched1[0].text, 'TASK: verify build 1.1.7+10');
    assert.equal(fetched1[0].senderName, 'mac-claude-e2e');

    // Re-fetch immediately after should be empty (already consumed + watermarked).
    const fetchedAgain = await linux.callTool('chattr_fetch', { chat_id: chatId });
    assert.equal((fetchedAgain as unknown[]).length, 0);

    // linux-claude replies -> mac-claude
    await linux.callTool('chattr_send', { chat_id: chatId, text: 'DONE: verified, all green' });
    const fetched2 = await mac.callTool<Array<{ text: string; senderName: string | null }>>('chattr_fetch', {
      chat_id: chatId,
    });
    assert.equal(fetched2.length, 1);
    assert.equal(fetched2[0].text, 'DONE: verified, all green');
    assert.equal(fetched2[0].senderName, 'linux-claude-e2e');

    // Local history reflects both directions on each side.
    const linuxHistory = await linux.callTool<Array<{ direction: string; plaintext: string }>>('chattr_history', {
      chat_id: chatId,
    });
    assert.equal(linuxHistory.length, 2);
    assert.deepEqual(
      linuxHistory.map((m) => m.direction),
      ['in', 'out'],
    );

    const macHistory = await mac.callTool<Array<{ direction: string; plaintext: string }>>('chattr_history', {
      chat_id: chatId,
    });
    assert.equal(macHistory.length, 2);
    assert.deepEqual(
      macHistory.map((m) => m.direction),
      ['out', 'in'],
    );
  } finally {
    linux.close();
    mac.close();
    rmSync(stateDir1, { recursive: true, force: true });
    rmSync(stateDir2, { recursive: true, force: true });
    rmSync(repoDir, { recursive: true, force: true });
  }
});
