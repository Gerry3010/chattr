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
//  4. the account's images in storage — see below
//
// Storage does NOT follow from any of that: `storage.objects` has no foreign
// key to profiles, so a deleted account's avatar stayed behind, and until
// migration 00075 lands it stayed behind *publicly readable* — the one piece
// of a deleted account still fetchable by anyone. Found 2026-08-13, together
// with three other orphans that scripts/cleanup-orphan-avatars.sh removed.
//
// Two buckets are ours to clean, one is not:
//  * `avatars/<userId>/…` — the account's own pictures, always ours. Listed by
//    FOLDER rather than read from profiles.avatar_path, because an upload with
//    a changed file extension leaves the previous object behind: the column
//    names one object, the folder holds every one of them.
//  * `group-avatars/<chatId>/…` — only for chats that the cascade in step 2
//    actually deleted (last member gone). A chat that outlives the account
//    keeps its picture; the members who stay would otherwise watch their group
//    lose its face because someone else left.
//  * `media/<chatId>/<messageId>/…` — deliberately NOT touched here. Those
//    blobs are unreadable the moment step 1 removes the envelopes carrying
//    their keys, and media_objects_to_reap() (00034) collects exactly that
//    case — unreferenced by any message row, after a 24h grace. Deleting them
//    here would duplicate that logic AND skip the grace period that protects
//    a send still in flight.
//
// The purge runs LAST and never fails the request: at that point the account
// is already gone, and a 500 would tell the client to retry a deletion that
// has already happened. Leftovers are reported in the response and land in the
// log — the cleanup script is the backstop.
//
// Exported so the auth gate is unit-testable without binding a port.
/// Which of the chats the user belonged to no longer exist — those are the
/// group pictures nobody owns anymore.
///
/// Pure on purpose: the interesting part is the set difference, and it is the
/// part that would quietly delete a living group's picture if it were wrong.
export function orphanedChatIds(
  memberChatIds: readonly string[],
  survivingChatIds: readonly string[],
): string[] {
  const alive = new Set(survivingChatIds);
  return [...new Set(memberChatIds)].filter((id) => !alive.has(id));
}

/// Full object paths for one folder listing.
///
/// `list()` returns names relative to the folder, and it returns two things
/// that are not files: nested folders (no `id`) and the zero-byte
/// `.emptyFolderPlaceholder` the dashboard leaves behind. Passing either to
/// `remove()` is a no-op at best, so they are dropped here.
export function objectPaths(
  folder: string,
  entries: readonly { name: string; id?: string | null }[],
): string[] {
  return entries
    .filter((e) => e.id != null && e.name !== ".emptyFolderPlaceholder")
    .map((e) => `${folder}/${e.name}`);
}

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
    // 0. The chats the user is in — read BEFORE the cascade, because
    //    chat_members is exactly what step 2 takes away. Without this list
    //    there is no way to tell afterwards which chats died with the account.
    const { data: memberships, error: memberError } = await admin
      .from("chat_members")
      .select("chat_id")
      .eq("user_id", userId);
    if (memberError) throw new Error(`chat_members: ${memberError.message}`);
    const memberChatIds = (memberships ?? [])
      .map((m: { chat_id: string }) => m.chat_id);

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

    // 4. Images. Past this line nothing may throw: the account is gone, and
    //    the caller must not be told to try again.
    const storage = { avatars: 0, group_avatars: 0, warnings: [] as string[] };

    const purge = async (bucket: string, folder: string): Promise<number> => {
      // `list()` returns 100 entries by default. An avatar folder holds one
      // object per file extension ever uploaded, so a handful — but a silent
      // truncation here reads as "cleaned up" while leaving pictures behind,
      // and that is the exact failure this whole change is about. Anything
      // past the cap is reported rather than quietly dropped.
      const LIMIT = 1000;
      const { data: entries, error: listError } = await admin.storage
        .from(bucket)
        .list(folder, { limit: LIMIT });
      if (listError) {
        storage.warnings.push(`list ${bucket}/${folder}: ${listError.message}`);
        return 0;
      }
      if ((entries ?? []).length >= LIMIT) {
        storage.warnings.push(
          `${bucket}/${folder}: more than ${LIMIT} objects — deleting the ` +
            `first page only, run scripts/cleanup-orphan-avatars.sh`,
        );
      }
      const paths = objectPaths(folder, entries ?? []);
      if (paths.length === 0) return 0;
      const { error: removeError } = await admin.storage
        .from(bucket)
        .remove(paths);
      if (removeError) {
        storage.warnings.push(
          `remove ${bucket}/${folder}: ${removeError.message}`,
        );
        return 0;
      }
      return paths.length;
    };

    try {
      storage.avatars = await purge("avatars", userId);

      if (memberChatIds.length > 0) {
        // Which of those chats survived the cascade? Asking for the survivors
        // rather than the dead ones keeps the failure safe: if this query
        // returns nothing because it errored, `orphanedChatIds` would call
        // every chat orphaned — so a failed read skips the step entirely.
        const { data: alive, error: chatError } = await admin
          .from("chats")
          .select("id")
          .in("id", memberChatIds);
        if (chatError) {
          storage.warnings.push(`chats: ${chatError.message}`);
        } else {
          const orphaned = orphanedChatIds(
            memberChatIds,
            (alive ?? []).map((c: { id: string }) => c.id),
          );
          for (const chatId of orphaned) {
            storage.group_avatars += await purge("group-avatars", chatId);
          }
        }
      }
    } catch (e) {
      storage.warnings.push(`${e}`);
    }

    if (storage.warnings.length > 0) {
      console.error(
        `delete-account: account ${userId} is gone, but images stayed:`,
        storage.warnings,
      );
    }

    return json({ deleted: true, user_id: userId, storage }, 200);
  } catch (e) {
    console.error(`delete-account failed for ${userId}:`, e);
    return json({ error: `${e}` }, 500);
  }
}

if (import.meta.main) {
  serve(handler);
}
