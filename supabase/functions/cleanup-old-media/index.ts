// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Deletes media-bucket objects that are due for retention. What is "due" is
// decided by the SQL function media_objects_to_reap() (migration 00034):
//   1. Unreferenced: all message rows for the blob's messageId are gone —
//      cleanup_old_messages() pruned them (every recipient read ≥7 days ago,
//      or unread for 30 days). Receipt alone must NOT delete the blob:
//      recipients decrypt the envelope (and media key) on delivery but
//      download the blob lazily on first view, so read+7d is their window
//      to still fetch the file. A 24h minimum age guards in-flight sends.
//   2. Hard 90-day age fallback.
// Direct SQL deletion of storage.objects is blocked by Supabase (and the
// storage schema is not exposed via PostgREST), so listing goes through the
// RPC and deletion through the Storage API with the service role. Scheduled
// daily by migration 00018 (pg_cron + pg_net). Only callers presenting the
// service-role key may run it.
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const BUCKET = "media";

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", {
      headers: { "Access-Control-Allow-Origin": "*" },
    });
  }

  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const url = Deno.env.get("SUPABASE_URL") ?? "";

  // Authorize: only the cron (service-role bearer) may trigger a bulk delete.
  const auth = req.headers.get("Authorization") ?? "";
  if (auth !== `Bearer ${serviceRoleKey}` || !serviceRoleKey) {
    return new Response(JSON.stringify({ error: "unauthorized" }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    });
  }

  const supabase = createClient(url, serviceRoleKey);

  const { data: rows, error } = await supabase.rpc("media_objects_to_reap");
  if (error) {
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  // Cap per run; the daily schedule drains any backlog.
  const names = (rows ?? [])
    .map((r: { name: string }) => r.name)
    .slice(0, 1000);

  let deleted = 0;
  if (names.length > 0) {
    const { error: delErr } = await supabase.storage.from(BUCKET).remove(names);
    if (delErr) {
      return new Response(JSON.stringify({ error: delErr.message }), {
        status: 500,
        headers: { "Content-Type": "application/json" },
      });
    }
    deleted = names.length;
  }

  console.log(`Media retention: deleted ${deleted} media object(s).`);
  return new Response(JSON.stringify({ deleted }), {
    headers: { "Content-Type": "application/json" },
  });
});
