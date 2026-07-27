// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Copyright (C) 2026 Gerald Hofbauer <info@geraldhofbauer.net>
// AGPLv3 — see <https://www.gnu.org/licenses/>.
//
// Proves chattr_wait is event-driven (Realtime broadcast) rather than the
// old 2s poll loop: it must return in well under 2000ms once a message
// actually arrives — a poll-driven implementation would occasionally take
// up to ~2000ms (and average ~1000ms) waiting for the next tick. Also
// covers the "message already there before chattr_wait was even called"
// gap-protection path. Requires local Supabase — skips otherwise, same
// pattern as two_agent_e2e.test.ts.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { McpStdioClient } from './mcp_stdio_client.js';

const SUPABASE_URL = process.env.SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SUPABASE_ANON_KEY =
  process.env.SUPABASE_ANON_KEY ??
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0';

// Generous — a poll-driven implementation would drift up toward 2000ms;
// event-driven delivery over a local Realtime connection is normally <200ms.
// 1500ms leaves headroom for CI/local jitter while still clearly failing if
// the old poll loop were reintroduced.
const LATENCY_BUDGET_MS = 1500;

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
  if (!res.ok || !data.access_token) throw new Error(`signup failed: ${JSON.stringify(data)}`);
  return { userId: data.user.id, accessToken: data.access_token };
}

async function createProfile(userId: string, username: string, accessToken: string): Promise<void> {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/profiles`, {
    method: 'POST',
    headers: { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${accessToken}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ id: userId, username }),
  });
  if (!res.ok) throw new Error(`createProfile failed: ${await res.text()}`);
}

async function mintOwnerToken(accessToken: string): Promise<string> {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/mint_mcp_token`, {
    method: 'POST',
    headers: { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${accessToken}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ p_label: 'realtime-wait-test' }),
  });
  const data = await res.json();
  if (!res.ok) throw new Error(`mint_mcp_token failed: ${JSON.stringify(data)}`);
  return data as string;
}

test('chattr_wait is Realtime-driven: returns well under the old 2s poll tick', async (t) => {
  if (!(await localSupabaseReachable())) {
    t.skip('local Supabase not reachable at ' + SUPABASE_URL + ' — run `supabase start` first');
    return;
  }

  const owner = await signUpAnon();
  await createProfile(owner.userId, 'e2e-owner-rt', owner.accessToken);
  const ownerToken = await mintOwnerToken(owner.accessToken);

  const stateDir1 = mkdtempSync(path.join(tmpdir(), 'chattr-agent-rt-a-'));
  const stateDir2 = mkdtempSync(path.join(tmpdir(), 'chattr-agent-rt-b-'));
  const repoDir = mkdtempSync(path.join(tmpdir(), 'chattr-rt-repo-'));
  // Isolate from the real ~/.claude/chattr-agents.json — tests must never write there.
  const globalRegistryPath = path.join(repoDir, 'global-registry.json');

  const agentA = new McpStdioClient(
    { SUPABASE_URL, SUPABASE_ANON_KEY, MCP_TOKEN: ownerToken, CHATTR_AGENT_STATE_DIR: stateDir1, CHATTR_GLOBAL_REGISTRY_PATH: globalRegistryPath },
    'agent-a',
  );
  const agentB = new McpStdioClient(
    { SUPABASE_URL, SUPABASE_ANON_KEY, CHATTR_AGENT_STATE_DIR: stateDir2, CHATTR_GLOBAL_REGISTRY_PATH: globalRegistryPath },
    'agent-b',
  );

  try {
    await agentA.initialize();
    await agentB.initialize();
    await agentA.callTool('chattr_init', { username: 'rt-agent-a' });
    await agentB.callTool('chattr_init', { username: 'rt-agent-b' });

    const ensured = await agentA.callTool<{ chatId: string }>('chattr_ensure_project_chat', {
      project: 'rt-test',
      repo_path: repoDir,
    });
    const chatId = ensured.chatId;

    await agentB.callTool('chattr_join', { chat_id: chatId });
    const pending = await agentA.callTool<{ pending: Array<{ userId: string }> }>('chattr_pending', {
      chat_id: chatId,
    });
    assert.equal(pending.pending.length, 1);
    await agentA.callTool('chattr_approve', { chat_id: chatId, user_id: pending.pending[0].userId });

    // --- Gap-protection: message already sent BEFORE chattr_wait is called ---
    await agentA.callTool('chattr_send', { chat_id: chatId, text: 'already here before the wait' });

    const t0 = Date.now();
    const preExisting = await agentB.callTool<Array<{ text: string }>>('chattr_wait', {
      chat_id: chatId,
      timeout_s: 10,
    });
    const preExistingMs = Date.now() - t0;

    assert.equal(preExisting.length, 1);
    assert.equal(preExisting[0].text, 'already here before the wait');
    assert.ok(
      preExistingMs < LATENCY_BUDGET_MS,
      `pre-existing message should return immediately, took ${preExistingMs}ms`,
    );

    // --- Realtime delivery: message sent WHILE chattr_wait is already blocked ---
    const waitPromise = agentB.callTool<Array<{ text: string }>>('chattr_wait', { chat_id: chatId, timeout_s: 15 });
    // Give chattr_wait a moment to actually establish its Realtime subscription
    // and complete its initial (empty) fetchMessages() before B sends.
    await new Promise((r) => setTimeout(r, 500));

    const tSend = Date.now();
    await agentA.callTool('chattr_send', { chat_id: chatId, text: 'realtime delivered' });

    const delivered = await waitPromise;
    const deliveredMs = Date.now() - tSend;

    assert.equal(delivered.length, 1);
    assert.equal(delivered[0].text, 'realtime delivered');
    assert.ok(
      deliveredMs < LATENCY_BUDGET_MS,
      `chattr_wait should return via Realtime well under ${LATENCY_BUDGET_MS}ms, took ${deliveredMs}ms (a 2s-poll implementation would drift toward 2000ms)`,
    );
  } finally {
    agentA.close();
    agentB.close();
    rmSync(stateDir1, { recursive: true, force: true });
    rmSync(stateDir2, { recursive: true, force: true });
    rmSync(repoDir, { recursive: true, force: true });
  }
});
