// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Copyright (C) 2026 Gerald Hofbauer <info@geraldhofbauer.net>
// AGPLv3 — see <https://www.gnu.org/licenses/>.
//
// Verifies migration 00041: revoking an MCP token removes agent members (every
// non-owner) from chats bound with that token, keeps the human owner, and lets
// the reassign-admin trigger promote the owner. Requires local Supabase with
// migrations applied — skips otherwise (same pattern as owner_auto_approve).

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

interface U { id: string; token: string; }
async function signUp(): Promise<U> {
  const r = await fetch(`${URL}/auth/v1/signup`, { method: 'POST', headers: { apikey: ANON, 'Content-Type': 'application/json' }, body: '{}' });
  const d = await r.json();
  return { id: d.user.id, token: d.access_token };
}
async function profile(u: U, n: string) {
  await fetch(`${URL}/rest/v1/profiles`, { method: 'POST', headers: { apikey: ANON, Authorization: `Bearer ${u.token}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ id: u.id, username: n }) });
}
async function rpc(u: U, fn: string, args: unknown) {
  const r = await fetch(`${URL}/rest/v1/rpc/${fn}`, { method: 'POST', headers: { apikey: ANON, Authorization: `Bearer ${u.token}`, 'Content-Type': 'application/json' }, body: JSON.stringify(args) });
  const t = await r.text();
  if (!r.ok) throw new Error(`${fn}: ${t}`);
  return t ? JSON.parse(t) : null;
}
async function ins(u: U, table: string, row: unknown, prefer = 'return=representation'): Promise<any> {
  const r = await fetch(`${URL}/rest/v1/${table}`, { method: 'POST', headers: { apikey: ANON, Authorization: `Bearer ${u.token}`, 'Content-Type': 'application/json', Prefer: prefer }, body: JSON.stringify(row) });
  const t = await r.text();
  if (!r.ok) throw new Error(`insert ${table}: ${t}`);
  return t ? JSON.parse(t) : null;
}
async function patch(u: U, path: string, row: unknown) {
  const r = await fetch(`${URL}/rest/v1/${path}`, { method: 'PATCH', headers: { apikey: ANON, Authorization: `Bearer ${u.token}`, 'Content-Type': 'application/json', Prefer: 'return=minimal' }, body: JSON.stringify(row) });
  if (!r.ok) throw new Error(await r.text());
}
async function del(u: U, path: string) {
  await fetch(`${URL}/rest/v1/${path}`, { method: 'DELETE', headers: { apikey: ANON, Authorization: `Bearer ${u.token}` } });
}
async function sel(u: U, path: string): Promise<any[]> {
  const r = await fetch(`${URL}/rest/v1/${path}`, { headers: { apikey: ANON, Authorization: `Bearer ${u.token}` } });
  return (await r.json()) as any[];
}

test('revoke_mcp_token removes agent members from bound chats, keeps the owner', async (t) => {
  if (!(await reachable())) {
    t.skip('local Supabase not reachable at ' + URL + ' — run `supabase start` first');
    return;
  }

  const owner = await signUp();
  const agent = await signUp();
  const agent2 = await signUp();
  await profile(owner, 'owner-' + owner.id.slice(0, 6));
  await profile(agent, 'agent-' + agent.id.slice(0, 6));
  await profile(agent2, 'agent2-' + agent2.id.slice(0, 6));

  const token = (await rpc(owner, 'mint_mcp_token', { p_label: 'revoke-test' })) as string;
  const tokenId = (await sel(owner, 'mcp_tokens?select=id&order=created_at.desc&limit=1'))[0].id;

  const chat = await ins(agent, 'chats', { is_group: true, name: 'agents:revoke-test' });
  const chatId = chat[0].id as string;
  await ins(agent, 'chat_members', { chat_id: chatId, user_id: agent.id }, 'return=minimal');
  await patch(agent, `chat_members?chat_id=eq.${chatId}&user_id=eq.${agent.id}`, { public_key: 'AGENT_PK' });
  await rpc(agent, 'bind_mcp_chat', { p_chat_id: chatId, p_token: token });

  const bound = await sel(owner, `chats?id=eq.${chatId}&select=mcp_owner_id,mcp_token_id`);
  assert.equal(bound[0].mcp_token_id, tokenId, 'bind stamped mcp_token_id');
  assert.equal(bound[0].mcp_owner_id, owner.id, 'bind stamped mcp_owner_id');

  // Owner joins (auto-approved by 00039); a second agent joins + is approved.
  // The OWNER approves: since 00044 the owner is the chat's sole admin and the
  // agent is demoted, so the agent can no longer admit anyone.
  await ins(owner, 'pending_chat_members', { chat_id: chatId, user_id: owner.id, public_key: 'OWNER_PK' }, 'return=minimal');
  await ins(agent2, 'pending_chat_members', { chat_id: chatId, user_id: agent2.id, public_key: 'AGENT2_PK' }, 'return=minimal');
  await del(owner, `pending_chat_members?chat_id=eq.${chatId}&user_id=eq.${agent2.id}`);
  await ins(owner, 'chat_members', { chat_id: chatId, user_id: agent2.id, public_key: 'AGENT2_PK' }, 'return=minimal');

  assert.equal((await sel(owner, `chat_members?chat_id=eq.${chatId}&select=user_id`)).length, 3, 'owner + 2 agents before revoke');

  await rpc(owner, 'revoke_mcp_token', { p_token_id: tokenId });

  assert.ok((await sel(owner, `mcp_tokens?id=eq.${tokenId}&select=revoked_at`))[0].revoked_at, 'token revoked');
  const after = await sel(owner, `chat_members?chat_id=eq.${chatId}&select=user_id`);
  assert.equal(after.length, 1, 'only one member remains');
  assert.equal(after[0].user_id, owner.id, 'the remaining member is the owner');
  assert.ok(
    ((await sel(owner, `chats?id=eq.${chatId}&select=admins`))[0].admins ?? []).includes(owner.id),
    'owner reassigned as admin',
  );
});
