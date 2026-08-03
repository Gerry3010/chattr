// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

// Deletes the CALLING user's account server-side. Anonymous accounts have no
// recovery path, so logout == account deletion: nothing may linger on the
// server (profiles has NO foreign key to auth.users — nothing cascades from
// deleting the auth user alone).
//
// Deletion order matters:
//  1. messages sent by the user (their sender_id FK on profiles is NO ACTION
//     and would block the profile delete; undelivered ciphertext from a
//     deleted account is intentionally dropped)
//  2. the profiles row — cascades chat_members, whose AFTER DELETE trigger
//     (reassign_admin_on_leave, 00020) reassigns admins / deletes chats that
//     end up empty
//  3. the auth.users row via the admin API — cascades the user's own message
//     copies, device_tokens and pending_chat_members
//
// Exported so the auth gate is unit-testable without binding a port.
export async function handler(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const json = (body: unknown, status: number) =>
    new Response(JSON.stringify(body), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status,
    });

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";

  // The caller must present their OWN valid user JWT — that is the entire
  // authorization model: you can only delete yourself.
  const authHeader = req.headers.get("Authorization") ?? "";
  const jwt = authHeader.replace(/^Bearer\s+/i, "");
  if (!jwt || !serviceRoleKey) {
    return json({ error: "Unauthorized" }, 401);
  }

  const userClient = createClient(supabaseUrl, anonKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { data: userData, error: userError } = await userClient.auth.getUser(
    jwt,
  );
  const userId = userData?.user?.id;
  if (userError || !userId) {
    return json({ error: "Unauthorized" }, 401);
  }

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  try {
    // 1. Undelivered ciphertext the user sent to others (their sender_id
    //    would otherwise block the profile delete).
    const { error: msgError } = await admin
      .from("messages")
      .delete()
      .eq("sender_id", userId);
    if (msgError) throw new Error(`messages: ${msgError.message}`);

    // 2. Profile → cascades chat_members → admin-reassign / orphan-chat
    //    trigger runs per membership.
    const { error: profileError } = await admin
      .from("profiles")
      .delete()
      .eq("id", userId);
    if (profileError) throw new Error(`profiles: ${profileError.message}`);

    // 3. Auth user → cascades own message copies, device_tokens,
    //    pending_chat_members; chats.created_by becomes NULL.
    const { error: authError } = await admin.auth.admin.deleteUser(userId);
    if (authError) throw new Error(`auth: ${authError.message}`);

    return json({ deleted: true, user_id: userId }, 200);
  } catch (e) {
    console.error(`delete-account failed for ${userId}:`, e);
    return json({ error: `${e}` }, 500);
  }
}

if (import.meta.main) {
  serve(handler);
}
