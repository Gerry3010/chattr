// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

const CHALLENGE_TTL_MS = 120_000;

// Abuse control (audit L4): a hard ceiling on outstanding (unexpired) challenge
// rows. The `challenge` action is anon-callable and inserts one row per DISTINCT
// public key, so without a bound an attacker spamming random keys could exhaust
// storage. The cleanup cron (migration 00050) sweeps expired rows; this caps the
// in-flight window. Generous enough never to touch legitimate recovery.
const MAX_OUTSTANDING_CHALLENGES = 10_000;

// Fire a best-effort out-of-band security alert to the recovered account's other
// devices (audit L3): a recovery = a full account takeover from a stolen phrase,
// and the legitimate device otherwise gets NO signal (the recovery keypair is
// separate from the identity key, so peers see no key-change banner either).
async function notifyAccountRecovered(
  supabaseUrl: string,
  serviceRoleKey: string,
  userId: string,
): Promise<void> {
  // Hard 5 s cap: a HANGING push endpoint must not delay (or, past the runtime
  // wall-clock, fail) a legitimate recovery that already minted its token.
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 5_000);
  try {
    await fetch(`${supabaseUrl}/functions/v1/send-push-notification`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${serviceRoleKey}`,
      },
      body: JSON.stringify({
        type: "security_alert",
        user_ids: [userId],
        title: "Account recovered on a new device",
        body:
          "If this wasn't you, someone used your recovery phrase — delete your account now.",
      }),
      signal: controller.signal,
    });
  } catch (e) {
    // Never fail the recovery itself because the alert couldn't be sent (or was
    // aborted by the timeout).
    console.error("recovery security alert failed (non-fatal):", e);
  } finally {
    clearTimeout(timer);
  }
}

// Recovers a user's identity on a fresh device from their recovery-phrase
// Ed25519 keypair (enrolled via enroll-recovery). ANON-callable — the caller
// has no session yet; authorization IS the signature over a server-issued,
// single-use challenge.
//
//   action:"challenge" { public_key }              -> { challenge }
//   action:"verify"    { public_key, challenge, signature } -> { token_hash }
//
// token_hash is then redeemed client-side via auth.verifyOtp({type:'magiclink',
// tokenHash}) to obtain a full session for the ORIGINAL user_id. No user email
// is ever exposed; public email auth stays disabled (the synthetic email is
// only touched by admin.generateLink here).
//
// The self-hosted edge runtime does NOT verify JWTs; this endpoint is
// deliberately unauthenticated and gates on the Ed25519 proof instead.
export async function handler(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const json = (body: unknown, status: number) =>
    new Response(JSON.stringify(body), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status,
    });

  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!serviceRoleKey) return json({ error: "Server misconfigured" }, 500);

  let body: {
    action?: unknown;
    public_key?: unknown;
    challenge?: unknown;
    signature?: unknown;
  };
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid JSON" }, 400);
  }

  const publicKey = body.public_key;
  if (typeof publicKey !== "string" || !decodeEd25519PublicKey(publicKey)) {
    return json({ error: "Invalid public_key" }, 400);
  }

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  try {
    if (body.action === "challenge") {
      // Abuse control (audit L4): refuse if too many challenges are already in
      // flight, bounding the storage-exhaustion vector. Counts only unexpired
      // rows so it self-heals as the TTL passes + the cleanup cron runs.
      const { count } = await admin
        .from("recovery_challenges")
        .select("recovery_public_key", { count: "exact", head: true })
        .gt("expires_at", new Date().toISOString());
      if ((count ?? 0) >= MAX_OUTSTANDING_CHALLENGES) {
        return json({ error: "Too many pending recovery challenges" }, 429);
      }

      // Issue a fresh single-use challenge. Issued regardless of whether the
      // key is enrolled (verify will reject unknown keys) — avoids enumeration.
      const challenge = base64(crypto.getRandomValues(new Uint8Array(32)));
      const expiresAt = new Date(Date.now() + CHALLENGE_TTL_MS).toISOString();
      const { error } = await admin.from("recovery_challenges").upsert(
        { recovery_public_key: publicKey, challenge, expires_at: expiresAt },
        { onConflict: "recovery_public_key" },
      );
      if (error) throw new Error(`challenge: ${error.message}`);
      return json({ challenge }, 200);
    }

    if (body.action === "verify") {
      const challenge = body.challenge;
      const signature = body.signature;
      if (typeof challenge !== "string" || typeof signature !== "string") {
        return json({ error: "challenge and signature required" }, 400);
      }

      // Consume the challenge single-use: fetch, then always delete.
      const { data: chalRow } = await admin
        .from("recovery_challenges")
        .select("challenge, expires_at")
        .eq("recovery_public_key", publicKey)
        .maybeSingle();
      await admin.from("recovery_challenges").delete().eq("recovery_public_key", publicKey);

      if (
        !chalRow ||
        chalRow.challenge !== challenge ||
        new Date(chalRow.expires_at).getTime() < Date.now()
      ) {
        return json({ error: "Invalid or expired challenge" }, 401);
      }

      // Verify the Ed25519 signature over the challenge string.
      const ok = await verifyEd25519(publicKey, challenge, signature);
      if (!ok) return json({ error: "Invalid signature" }, 401);

      // Signature is valid — resolve the enrolled user + synthetic email.
      const { data: cred } = await admin
        .from("recovery_credentials")
        .select("user_id, synthetic_email")
        .eq("recovery_public_key", publicKey)
        .maybeSingle();
      if (!cred) return json({ error: "Not enrolled" }, 401);

      // Mint a magiclink token_hash for the original user via the admin API.
      const { data: link, error: linkError } = await admin.auth.admin.generateLink({
        type: "magiclink",
        email: cred.synthetic_email,
      });
      if (linkError) throw new Error(`generateLink: ${linkError.message}`);
      const tokenHash =
        (link as { properties?: { hashed_token?: string } })?.properties?.hashed_token ??
        (link as { hashed_token?: string })?.hashed_token;
      if (!tokenHash) throw new Error("generateLink returned no token_hash");

      // Out-of-band alert to the account's existing devices (audit L3). Awaited
      // but non-fatal — a stolen phrase must not also suppress the warning, yet
      // a push outage must not block a legitimate recovery.
      await notifyAccountRecovered(supabaseUrl, serviceRoleKey, cred.user_id);

      return json({ token_hash: tokenHash }, 200);
    }

    return json({ error: "Unknown action" }, 400);
  } catch (e) {
    console.error("recover-identity failed:", e);
    return json({ error: `${e}` }, 500);
  }
}

function decodeEd25519PublicKey(s: string): Uint8Array | null {
  try {
    const bytes = Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
    return bytes.length === 32 ? bytes : null;
  } catch {
    return null;
  }
}

function base64(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes));
}

async function verifyEd25519(
  publicKeyB64: string,
  message: string,
  signatureB64: string,
): Promise<boolean> {
  try {
    const pub = decodeEd25519PublicKey(publicKeyB64);
    if (!pub) return false;
    const sig = Uint8Array.from(atob(signatureB64), (c) => c.charCodeAt(0));
    if (sig.length !== 64) return false;
    const key = await crypto.subtle.importKey(
      "raw",
      pub,
      { name: "Ed25519" },
      false,
      ["verify"],
    );
    return await crypto.subtle.verify(
      "Ed25519",
      key,
      sig,
      new TextEncoder().encode(message),
    );
  } catch {
    return false;
  }
}

if (import.meta.main) {
  serve(handler);
}
