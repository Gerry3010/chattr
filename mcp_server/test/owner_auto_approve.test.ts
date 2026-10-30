// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Copyright (C) 2026 Gerald Hofbauer <info@geraldhofbauer.net>
// AGPLv3 — see <https://www.gnu.org/licenses/>.
//
// Verifies migration 00039 (auto_approve_mcp_owner): when the bound owner of an
// MCP chat files a join request, a SECURITY DEFINER AFTER INSERT trigger on
// pending_chat_members promotes them straight to a member (with the public_key
// they submitted) and clears the pending row — while a non-owner request still
// lands in the pending queue. Requires local Supabase with migrations applied —
// skips otherwise, same pattern as realtime_wait.test.ts.

import { test } from 'node:test';
import assert from 'node:assert/strict';

const URL = process.env.SUPABASE_URL ?? 'http://127.0.0.1:54321';
const ANON =
  process.env.SUPABASE_ANON_KEY ??
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0';

async function reachable(): Promise<boolean> {
  try {
    const r = await fetch(`${URL}/auth/v1/health`, { signal: AbortSignal.timeout(2000) });
    return r.ok;
  } catch {
    return false;
  }
}

interface User {
  id: string;
  token: string;
}

async function signUp(): Promise<User> {
  const r = await fetch(`${URL}/auth/v1/signup`, {
    method: 'POST',
    headers: { apikey: ANON, 'Content-Type': 'application/json' },
    body: '{}',
  });
  const d = await r.json();
  if (!d.access_token) throw new Error('signup failed: ' + JSON.stringify(d));
  return { id: d.user.id, token: d.access_token };
}

async function createProfile(u: User, username: string): Promise<void> {
  const r = await fetch(`${URL}/rest/v1/profiles`, {
    method: 'POST',
    headers: { apikey: ANON, Authorization: `Bearer ${u.token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ id: u.id, username }),
  });
  if (!r.ok) throw new Error('createProfile: ' + (await r.text()));
}

async function rpc(u: User, fn: string, args: unknown): Promise<unknown> {
  const r = await fetch(`${URL}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: { apikey: ANON, Authorization: `Bearer ${u.token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(args),
  });
  const t = await r.text();
  if (!r.ok) throw new Error(`${fn}: ${t}`);
  return t ? JSON.parse(t) : null;
}

async function insert(u: User, table: string, row: unknown, prefer = 'return=representation'): Promise<any> {
  const r = await fetch(`${URL}/rest/v1/${table}`, {
    method: 'POST',
    headers: { apikey: ANON, Authorization: `Bearer ${u.token}`, 'Content-Type': 'application/json', Prefer: prefer },
    body: JSON.stringify(row),
  });
  const t = await r.text();
  if (!r.ok) throw new Error(`insert ${table}: ${t}`);
  return t ? JSON.parse(t) : null;
}

async function patch(u: User, path: string, row: unknown): Promise<void> {
  const r = await fetch(`${URL}/rest/v1/${path}`, {
    method: 'PATCH',
    headers: { apikey: ANON, Authorization: `Bearer ${u.token}`, 'Content-Type': 'application/json', Prefer: 'return=minimal' },
    body: JSON.stringify(row),
  });
  if (!r.ok) throw new Error(`patch ${path}: ${await r.text()}`);
}

async function select(u: User, path: string): Promise<any[]> {
  const r = await fetch(`${URL}/rest/v1/${path}`, {
    headers: { apikey: ANON, Authorization: `Bearer ${u.token}` },
  });
  return (await r.json()) as any[];
}

test('auto_approve_mcp_owner: owner is promoted on join, non-owner still queues', async (t) => {
  if (!(await reachable())) {
    t.skip('local Supabase not reachable at ' + URL + ' — run `supabase start` first');
    return;
  }

  const owner = await signUp();
  const agent = await signUp();
  await createProfile(owner, 'owner-' + owner.id.slice(0, 6));
  await createProfile(agent, 'agent-' + agent.id.slice(0, 6));

  // Owner mints a token; agent creates a chat, joins it, binds it to the owner.
  const mcpToken = await rpc(owner, 'mint_mcp_token', { p_label: 'autoapprove-test' });
  const chat = await insert(agent, 'chats', { is_group: true, name: 'agents:autoapprove-test' });
  const chatId = chat[0].id as string;
  // Mirror ensureProjectChat: add self WITHOUT public_key, then UPDATE it (a plain
  // authenticated INSERT can't set public_key — which is exactly why the owner
  // promotion needs a SECURITY DEFINER trigger).
  await insert(agent, 'chat_members', { chat_id: chatId, user_id: agent.id }, 'return=minimal');
  await patch(agent, `chat_members?chat_id=eq.${chatId}&user_id=eq.${agent.id}`, { public_key: 'AGENT_PUBKEY' });
  const ownerId = await rpc(agent, 'bind_mcp_chat', { p_chat_id: chatId, p_token: mcpToken });
  assert.equal(ownerId, owner.id, 'bind_mcp_chat stamped the owner');

  // The owner's app files its join request (pending) with its E2E public key.
  await insert(
    owner,
    'pending_chat_members',
    { chat_id: chatId, user_id: owner.id, public_key: 'OWNER_PUBKEY' },
    'return=minimal',
  );

  // Trigger ran synchronously: owner is a member with their key, pending cleared.
  const members = await select(agent, `chat_members?chat_id=eq.${chatId}&select=user_id,public_key`);
  const ownerMember = members.find((m) => m.user_id === owner.id);
  assert.ok(ownerMember, 'owner was auto-promoted into chat_members');
  assert.equal(ownerMember.public_key, 'OWNER_PUBKEY', 'owner joined with the SAME public_key (E2E identity preserved)');

  const pending = await select(agent, `pending_chat_members?chat_id=eq.${chatId}&user_id=eq.${owner.id}&select=user_id`);
  assert.equal(pending.length, 0, 'owner pending row was cleared');

  // Negative control: a non-owner request must still land in pending.
  const stranger = await signUp();
  await createProfile(stranger, 'stranger-' + stranger.id.slice(0, 6));
  await insert(
    stranger,
    'pending_chat_members',
    { chat_id: chatId, user_id: stranger.id, public_key: 'STRANGER_PUBKEY' },
    'return=minimal',
  );
  // Read as the owner: since 00044 the owner is the sole admin, and only admins
  // see the pending queue (the demoted agent gets an empty list).
  const strangerMembers = await select(owner, `chat_members?chat_id=eq.${chatId}&user_id=eq.${stranger.id}&select=user_id`);
  assert.equal(strangerMembers.length, 0, 'non-owner is NOT auto-approved');
  const strangerPending = await select(owner, `pending_chat_members?chat_id=eq.${chatId}&user_id=eq.${stranger.id}&select=user_id`);
  assert.equal(strangerPending.length, 1, 'non-owner request stays in the pending queue');
});
