// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

// Enrolls the CALLING user's recovery-phrase public key so they can later
// recover their identity on a fresh device (see recover-identity). Requires a
// valid user session — you can only enroll recovery for yourself.
//
// It attaches a random synthetic email to the user server-side (admin API,
// pre-confirmed) purely so recover-identity's admin.generateLink() works; the
// user never sees it and public email auth stays disabled. Re-enrolling (a new
// phrase) overwrites the stored public key + synthetic email, invalidating the
// old phrase.
//
// The self-hosted edge runtime does NOT verify JWTs, so the gate lives here.
// Exported so that gate is unit-testable without binding a port.
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
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";

  // Gate: caller must present their own valid user JWT.
  const authHeader = req.headers.get("Authorization") ?? "";
  const jwt = authHeader.replace(/^Bearer\s+/i, "");
  if (!jwt || !serviceRoleKey) return json({ error: "Unauthorized" }, 401);

  const userClient = createClient(supabaseUrl, anonKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { data: userData, error: userError } = await userClient.auth.getUser(jwt);
  const userId = userData?.user?.id;
  if (userError || !userId) return json({ error: "Unauthorized" }, 401);

  let body: { public_key?: unknown };
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid JSON" }, 400);
  }
  const publicKey = body.public_key;
  if (typeof publicKey !== "string" || !isBase64Ed25519PublicKey(publicKey)) {
    return json({ error: "public_key must be a base64 32-byte Ed25519 key" }, 400);
  }

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  try {
    const syntheticEmail = `rec_${crypto.randomUUID().replace(/-/g, "")}@recovery.chattr`;

    // Attach + pre-confirm the synthetic email so generateLink works later.
    const { error: emailError } = await admin.auth.admin.updateUserById(userId, {
      email: syntheticEmail,
      email_confirm: true,
    });
    if (emailError) throw new Error(`set email: ${emailError.message}`);

    const { error: upsertError } = await admin
      .from("recovery_credentials")
      .upsert(
        {
          user_id: userId,
          recovery_public_key: publicKey,
          synthetic_email: syntheticEmail,
        },
        { onConflict: "user_id" },
      );
    if (upsertError) throw new Error(`upsert: ${upsertError.message}`);

    return json({ enrolled: true }, 200);
  } catch (e) {
    console.error(`enroll-recovery failed for ${userId}:`, e);
    return json({ error: `${e}` }, 500);
  }
}

function isBase64Ed25519PublicKey(s: string): boolean {
  try {
    const bytes = Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
    return bytes.length === 32;
  } catch {
    return false;
  }
}

if (import.meta.main) {
  serve(handler);
}
