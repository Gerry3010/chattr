// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Copyright (C) 2026 Gerald Hofbauer <info@geraldhofbauer.net>
// AGPLv3 — see <https://www.gnu.org/licenses/>.
//
// Chat lifecycle: create+bind a project chat, join an existing one, and the
// admin-side pending/approve flow. Mirrors chats_controller.dart's
// createGroupChat + pending_chat_members_repository.dart exactly (same
// insert/update sequence) so agent-created chats behave identically to
// ones created by the real app.

import type { SupabaseClient } from '@supabase/supabase-js';
import { generateChatKeyPair, encodePublicKeyBlob, signPublicKeyBlob, type ChatKeyPair } from './crypto_port.js';
import { ensureIdentity } from './identity.js';
import { loadChatKeyPair, saveChatKeyPair } from './state.js';
import { readRegistry, readGlobalChatId, writeRegistry } from './registry.js';
import { config } from './config.js';

export interface ChatRow {
  id: string;
  name: string | null;
  is_group: boolean;
  is_mcp: boolean;
  mcp_owner_id: string | null;
  admins: string[];
}

/** Returns the caller's stored keypair for a chat, or throws — used once we're already a member (the key must have been generated at join/create time). */
export function requireLocalKeyPair(chatId: string): ChatKeyPair {
  const existing = loadChatKeyPair(chatId);
  if (!existing) {
    throw new Error(`No local key pair for chat ${chatId} — join or create the chat first.`);
  }
  return existing;
}

async function generateAndSave(chatId: string): Promise<ChatKeyPair> {
  const pair = await generateChatKeyPair();
  saveChatKeyPair(chatId, pair);
  return pair;
}

/**
 * Identity-signed public-key blob for registration (audit C1) — peers verify
 * the signature against the agent's pinned identity key. Falls back to the
 * unsigned blob on error (peers then just see the key as unverified).
 */
async function signedPublicKeyBlob(chatId: string, pair: ChatKeyPair): Promise<string> {
  const blob = encodePublicKeyBlob(pair);
  try {
    return await signPublicKeyBlob(await ensureIdentity(), chatId, blob);
  } catch {
    return blob;
  }
}

/**
 * Creates a fresh group chat named `agents:<project>`, registers the
 * caller's own key (mirrors createGroupChat's create -> generate keypair ->
 * setPublicKey sequence), binds it to the owner's MCP token, and records it
 * in `.chattr-agents.json` at repoPath. If a registry entry already exists
 * for this repo, returns it as-is (idempotent — safe to call repeatedly).
 * Checks the repo-local registry first, then the global one (`~/.claude/
 * chattr-agents.json`) — this server is registered machine-wide, so a chat
 * already created for this project from a DIFFERENT cwd must still be found
 * here instead of creating a duplicate "agents:<project>" chat.
 */
export async function ensureProjectChat(
  client: SupabaseClient,
  userId: string,
  project: string,
  repoPath: string,
): Promise<{ chatId: string; ownerId: string; created: boolean }> {
  const repoEntry = readRegistry(repoPath);
  const existingChatId = repoEntry?.project === project ? repoEntry.chat_id : readGlobalChatId(project);
  if (existingChatId) {
    const { data: chat } = await client
      .from('chats')
      .select('id, mcp_owner_id')
      .eq('id', existingChatId)
      .maybeSingle();
    if (chat) {
      // Found via the global registry but not yet recorded for this repo — sync it.
      if (repoEntry?.project !== project) writeRegistry(repoPath, { project, chat_id: existingChatId });
      return { chatId: existingChatId, ownerId: chat.mcp_owner_id as string, created: false };
    }
    // Registry pointed at a chat we can no longer see (deleted?) — fall through and recreate.
  }

  if (!config.mcpToken) {
    throw new Error(
      'MCP_TOKEN is not set — mint one in the Chattr app (Settings > MCP) and put it in mcp_server/.env before creating a project chat.',
    );
  }

  const { data: chatRes, error: chatError } = await client
    .from('chats')
    .insert({ is_group: true, name: `agents:${project}` })
    .select()
    .single();
  if (chatError || !chatRes) {
    throw new Error(`Failed to create chat: ${chatError?.message}`);
  }
  const chatId = chatRes.id as string;

  const { error: memberError } = await client.from('chat_members').insert({ chat_id: chatId, user_id: userId });
  if (memberError) {
    throw new Error(`Failed to add self as member: ${memberError.message}`);
  }

  const pair = await generateAndSave(chatId);
  const { error: keyError } = await client
    .from('chat_members')
    .update({ public_key: await signedPublicKeyBlob(chatId, pair) })
    .match({ chat_id: chatId, user_id: userId });
  if (keyError) {
    throw new Error(`Failed to register public key: ${keyError.message}`);
  }

  const { data: ownerId, error: bindError } = await client.rpc('bind_mcp_chat', {
    p_chat_id: chatId,
    p_token: config.mcpToken,
  });
  if (bindError) {
    throw new Error(`Failed to bind chat to owner token: ${bindError.message}`);
  }

  writeRegistry(repoPath, { project, chat_id: chatId });

  return { chatId, ownerId: ownerId as string, created: true };
}

/**
 * Resolves a chat_id from an explicit id, or a project name — repo-local
 * registry first, then the global one (`~/.claude/chattr-agents.json`), so
 * a project's chat is reachable by name regardless of the current cwd.
 */
export function resolveChatId(project: string | undefined, chatId: string | undefined, repoPath: string): string {
  if (chatId) return chatId;
  if (project) {
    const entry = readRegistry(repoPath);
    if (entry?.project === project) return entry.chat_id;
    const globalChatId = readGlobalChatId(project);
    if (globalChatId) return globalChatId;
    throw new Error(`No registered chat for project "${project}" (checked ${repoPath}/.chattr-agents.json and ~/.claude/chattr-agents.json)`);
  }
  throw new Error('Provide either project or chat_id.');
}

/** Headless join: generate/reuse a per-chat keypair, request membership. No-ops if already a member or already pending. */
export async function joinChat(
  client: SupabaseClient,
  userId: string,
  chatId: string,
): Promise<{ status: 'already_member' | 'already_pending' | 'requested' }> {
  const { data: member } = await client
    .from('chat_members')
    .select('user_id')
    .match({ chat_id: chatId, user_id: userId })
    .maybeSingle();
  if (member) return { status: 'already_member' };

  const { data: pending } = await client
    .from('pending_chat_members')
    .select('user_id')
    .match({ chat_id: chatId, user_id: userId })
    .maybeSingle();
  if (pending) return { status: 'already_pending' };

  const pair = await generateAndSave(chatId);
  const { error } = await client.from('pending_chat_members').insert({
    chat_id: chatId,
    user_id: userId,
    public_key: await signedPublicKeyBlob(chatId, pair),
  });
  if (error) {
    throw new Error(`Failed to request to join: ${error.message}`);
  }
  return { status: 'requested' };
}

export interface PendingEntry {
  userId: string;
  username: string | null;
  createdAt: string;
}

export async function listPending(client: SupabaseClient, chatId: string): Promise<PendingEntry[]> {
  const { data, error } = await client
    .from('pending_chat_members')
    .select('user_id, created_at')
    .eq('chat_id', chatId)
    .is('blocked_at', null)
    .order('created_at', { ascending: true });
  if (error) throw new Error(`Failed to list pending members: ${error.message}`);
  const rows = data ?? [];
  if (rows.length === 0) return [];

  // No FK between pending_chat_members and profiles for PostgREST to embed —
  // both reference auth.users independently — so resolve usernames separately.
  const userIds = rows.map((r: any) => r.user_id as string);
  const { data: profiles } = await client.from('profiles').select('id, username').in('id', userIds);
  const usernameById = new Map((profiles ?? []).map((p: any) => [p.id as string, p.username as string]));

  return rows.map((row: any) => ({
    userId: row.user_id as string,
    username: usernameById.get(row.user_id as string) ?? null,
    createdAt: row.created_at as string,
  }));
}

/** Approves a pending member — delete pending row, insert chat_members with the SAME public_key they submitted at request time. Admin-only via RLS. */
export async function approvePending(client: SupabaseClient, chatId: string, userId: string): Promise<void> {
  const { data: pending, error: fetchError } = await client
    .from('pending_chat_members')
    .select('public_key')
    .match({ chat_id: chatId, user_id: userId })
    .maybeSingle();
  if (fetchError || !pending) {
    throw new Error(`No pending request found for user ${userId} in chat ${chatId}`);
  }

  const { error: deleteError } = await client
    .from('pending_chat_members')
    .delete()
    .match({ chat_id: chatId, user_id: userId });
  if (deleteError) throw new Error(`Failed to remove pending request: ${deleteError.message}`);

  const { error: insertError } = await client
    .from('chat_members')
    .insert({ chat_id: chatId, user_id: userId, public_key: pending.public_key });
  if (insertError) throw new Error(`Failed to add chat member: ${insertError.message}`);
}

export async function getChatInfo(client: SupabaseClient, chatId: string): Promise<ChatRow> {
  const { data, error } = await client
    .from('chats')
    .select('id, name, is_group, is_mcp, mcp_owner_id, admins')
    .eq('id', chatId)
    .single();
  if (error || !data) throw new Error(`Chat not found: ${error?.message}`);
  return data as ChatRow;
}

export interface MemberKey {
  userId: string;
  publicKey: string;
}

/** All OTHER members' public-key blobs for a chat — mirrors ChatMemberKeysRepository.getAllPublicKeys minus the sender. */
export async function getOtherMemberKeys(
  client: SupabaseClient,
  chatId: string,
  selfUserId: string,
): Promise<MemberKey[]> {
  const { data, error } = await client
    .from('chat_members')
    .select('user_id, public_key')
    .eq('chat_id', chatId)
    .not('public_key', 'is', null);
  if (error) throw new Error(`Failed to load member keys: ${error.message}`);
  return (data ?? [])
    .filter((r: any) => r.user_id !== selfUserId)
    .map((r: any) => ({ userId: r.user_id as string, publicKey: r.public_key as string }));
}
