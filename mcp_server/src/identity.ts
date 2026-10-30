// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Agent-side identity key (audit C1/H1): one long-term Ed25519 keypair per
// agent profile, generated on first use, published to
// profiles.identity_public_key so peers can pin/verify it — the exact
// counterpart of the app's IdentityKeyManager + ChatsController publish flow.

import type { SupabaseClient } from '@supabase/supabase-js';
import { generateIdentityKeyPair, type IdentityKeyPair } from './crypto_port.js';
import { loadIdentityKeyPair, saveIdentityKeyPair } from './state.js';

export async function ensureIdentity(): Promise<IdentityKeyPair> {
  let pair = loadIdentityKeyPair();
  if (!pair) {
    pair = await generateIdentityKeyPair();
    saveIdentityKeyPair(pair);
  }
  return pair;
}

let publishedThisRun = false;

/**
 * Ensure the identity key exists AND its public half is published on the
 * agent's profile (idempotent; checked once per process). Publish failures
 * are non-fatal — peers just see the agent as unverified (warn-only model).
 */
export async function ensureIdentityPublished(
  client: SupabaseClient,
  userId: string,
): Promise<IdentityKeyPair> {
  const pair = await ensureIdentity();
  if (publishedThisRun) return pair;
  try {
    const { data } = await client
      .from('profiles')
      .select('identity_public_key')
      .eq('id', userId)
      .maybeSingle();
    if (data?.identity_public_key !== pair.pub) {
      await client.from('profiles').update({ identity_public_key: pair.pub }).eq('id', userId);
    }
    publishedThisRun = true;
  } catch {
    // retry on the next send
  }
  return pair;
}
