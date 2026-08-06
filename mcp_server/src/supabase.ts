// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Copyright (C) 2026 Gerald Hofbauer <info@geraldhofbauer.net>
// AGPLv3 — see <https://www.gnu.org/licenses/>.
//
// A full anon-key Supabase client — no service role, ever. Identity comes
// from an anonymous auth session persisted via state.ts's file-backed
// storage adapter, mirroring lib/features/auth/auth_repository.dart.

import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { config } from './config.js';
import { sessionStorage } from './state.js';

let _client: SupabaseClient | null = null;

export function getClient(): SupabaseClient {
  if (_client) return _client;
  if (!config.supabaseAnonKey) {
    throw new Error('SUPABASE_ANON_KEY is not set (see mcp_server/.env.example)');
  }
  _client = createClient(config.supabaseUrl, config.supabaseAnonKey, {
    auth: {
      storage: sessionStorage,
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: false,
    },
  });
  return _client;
}

export async function currentUserId(): Promise<string | null> {
  const { data } = await getClient().auth.getSession();
  return data.session?.user.id ?? null;
}

export async function requireUserId(): Promise<string> {
  const id = await currentUserId();
  if (!id) {
    throw new Error('Not initialized — call chattr_init first.');
  }
  return id;
}

/**
 * chattr_init: signs in anonymously ONCE and creates the profile row.
 * Idempotent — a restored session (session.json already holds a refresh
 * token) is left alone; re-running chattr_init on an existing identity
 * would otherwise orphan every chat that identity already joined.
 */
export async function initIdentity(
  username: string,
): Promise<{ userId: string; alreadyInitialized: boolean }> {
  const client = getClient();
  const existing = await currentUserId();
  if (existing) {
    return { userId: existing, alreadyInitialized: true };
  }

  const { data, error } = await client.auth.signInAnonymously();
  if (error || !data.user) {
    throw new Error(`signInAnonymously failed: ${error?.message ?? 'no user returned'}`);
  }
  const userId = data.user.id;

  // is_agent: self-declaration for the app's agents section (00068) —
  // display-only, no rights hang off it. Fallback without the column keeps
  // init working against a backend that predates the migration.
  let { error: profileError } = await client
    .from('profiles')
    .insert({ id: userId, username, is_agent: true });
  if (profileError && profileError.message.includes('is_agent')) {
    ({ error: profileError } = await client.from('profiles').insert({ id: userId, username }));
  }
  if (profileError) {
    throw new Error(`Failed to create profile: ${profileError.message}`);
  }

  return { userId, alreadyInitialized: false };
}

export async function getUsername(userId: string): Promise<string | null> {
  const { data } = await getClient().from('profiles').select('username').eq('id', userId).maybeSingle();
  return (data?.username as string | undefined) ?? null;
}
