// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// admin-stats — read-only aggregate metrics + moderation actions + operator
// management for the internal admin dashboard. EVERYTHING here is metadata-only:
// it calls service_role-locked SECURITY DEFINER RPCs (migrations 00058-00061)
// which never read, decrypt, or expose message content. No message body ever
// passes through.
//
// AUTH — two layers:
//  1. NETWORK GATE (always): a bearer == ADMIN_STATS_SECRET, injected server-side
//     by the admin-proxy sidecar (never held by the browser). The self-hosted
//     edge runtime does not verify JWTs, so this function gates itself.
//  2. OPERATOR SESSION (once any operator exists): a stateless HMAC token issued
//     by `login` (signed with ADMIN_STATS_SECRET, 12h TTL), sent as X-Admin-Session.
//     - 0 operators  → legacy single-operator mode: the network gate alone is
//       enough (backwards compatible). `operator_add` is bootstrap-callable.
//     - >0 operators → every action except whoami/login needs a valid session;
//       admin-only actions (operators/settings/watchlists/audit) need role=admin.
//     Actions are attributed to the operator (p_by) → admin_audit.
//
// Reachable at: <api>/functions/v1/admin-stats?action=stats&bucket=day

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-admin-session",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });

const BUCKETS = new Set(["day", "week", "month"]);
const SESSION_TTL_MS = 12 * 60 * 60 * 1000; // 12h

// Actions requiring role=admin (once operators exist).
const ADMIN_ACTIONS = new Set([
  "operators", "operator_add", "operator_disable", "operator_set_role",
  "operator_set_password", "settings", "settings_set",
  "lists", "list_terms", "list_add", "list_rename", "list_set_enabled",
  "list_delete", "term_add", "term_remove", "list_export", "list_import",
  "audit",
]);
// Actions any authenticated operator may perform (reads + moderation).
// (Everything not in ADMIN_ACTIONS and not whoami/login.)

// ---------------------------------------------------------------------------
// Stateless HMAC session tokens
// ---------------------------------------------------------------------------
const te = new TextEncoder();
const td = new TextDecoder();

function b64urlEncode(bytes: Uint8Array): string {
  let s = btoa(String.fromCharCode(...bytes));
  return s.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
function b64urlDecode(s: string): Uint8Array {
  s = s.replace(/-/g, "+").replace(/_/g, "/");
  while (s.length % 4) s += "=";
  return Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
}
async function hmacKey(secret: string): Promise<CryptoKey> {
  return await crypto.subtle.importKey(
    "raw", te.encode(secret), { name: "HMAC", hash: "SHA-256" }, false,
    ["sign", "verify"],
  );
}
async function signSession(
  payload: Record<string, unknown>, secret: string,
): Promise<string> {
  const body = b64urlEncode(te.encode(JSON.stringify(payload)));
  const key = await hmacKey(secret);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, te.encode(body)));
  return `${body}.${b64urlEncode(sig)}`;
}
interface Session { operator_id: string; username: string; role: string; exp: number; }
async function verifySession(token: string, secret: string): Promise<Session | null> {
  try {
    const [body, sig] = token.split(".");
    if (!body || !sig) return null;
    const key = await hmacKey(secret);
    const ok = await crypto.subtle.verify(
      "HMAC", key, b64urlDecode(sig) as BufferSource, te.encode(body));
    if (!ok) return null;
    const obj = JSON.parse(td.decode(b64urlDecode(body))) as Session;
    if (!obj.exp || obj.exp < Date.now()) return null;
    return obj;
  } catch {
    return null;
  }
}

// deno-lint-ignore no-explicit-any
async function operatorCount(supabase: any): Promise<number> {
  const { data, error } = await supabase.rpc("admin_operator_count");
  if (error) throw error;
  return Number(data ?? 0);
}

export async function handler(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const adminSecret = Deno.env.get("ADMIN_STATS_SECRET") ?? "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";

  // Fail closed if the gate secret isn't configured — never fall through open.
  if (!adminSecret) {
    return json({ error: "ADMIN_STATS_SECRET not configured" }, 500);
  }

  // Layer 1 — network gate: reject any caller whose bearer ≠ the admin secret.
  const authHeader = req.headers.get("Authorization") ?? "";
  const token = authHeader.replace(/^Bearer\s+/i, "");
  if (token !== adminSecret) {
    return json({ error: "Unauthorized" }, 401);
  }

  const supabase = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  const url = new URL(req.url);
  const action = url.searchParams.get("action") ?? "stats";

  // deno-lint-ignore no-explicit-any
  const readBody = async (): Promise<any> => await req.json().catch(() => ({}));

  try {
    // ---- unauthenticated-by-session actions (still behind the network gate) --
    if (action === "whoami") {
      const count = await operatorCount(supabase);
      const sh = req.headers.get("X-Admin-Session") ?? "";
      const sess = sh ? await verifySession(sh, adminSecret) : null;
      return json({
        requiresLogin: count > 0,
        role: sess?.role ?? null,
        username: sess?.username ?? null,
      });
    }

    if (action === "login") {
      if (req.method !== "POST") return json({ error: "POST required" }, 405);
      const body = await readBody();
      if (!body.username || !body.password) {
        return json({ error: "expected { username, password }" }, 400);
      }
      const { data, error } = await supabase.rpc("admin_login", {
        p_username: body.username, p_password: body.password,
      });
      if (error) throw error;
      const row = Array.isArray(data) ? data[0] : null;
      if (!row) return json({ error: "invalid credentials" }, 401);
      const tok = await signSession({
        operator_id: row.operator_id, username: row.username,
        role: row.role, exp: Date.now() + SESSION_TTL_MS,
      }, adminSecret);
      return json({ token: tok, username: row.username, role: row.role });
    }

    // ---- Layer 2 — operator session authz for everything else ---------------
    const count = await operatorCount(supabase);
    const sh = req.headers.get("X-Admin-Session") ?? "";
    const session = sh ? await verifySession(sh, adminSecret) : null;
    const isBootstrap = action === "operator_add" && count === 0;

    if (count > 0) {
      if (!session) return json({ error: "login required" }, 401);
      if (ADMIN_ACTIONS.has(action) && session.role !== "admin") {
        return json({ error: "admin role required" }, 403);
      }
    }
    const p_by = session?.operator_id ?? null;

    switch (action) {
      // ---------- reads ----------
      case "stats": {
        const bucket = url.searchParams.get("bucket") ?? "day";
        if (!BUCKETS.has(bucket)) {
          return json({ error: `invalid bucket '${bucket}'` }, 400);
        }
        return json(await collectStats(supabase, bucket));
      }
      case "reports": {
        const includeResolved = url.searchParams.get("resolved") === "true";
        const { data, error } = await supabase.rpc("mod_report_queue", {
          p_include_resolved: includeResolved,
        });
        if (error) throw error;
        return json({ reports: data ?? [] });
      }
      case "signals": {
        const { data, error } = await supabase.rpc("abuse_signals");
        if (error) throw error;
        return json({ signals: data ?? [] });
      }
      case "enforcement": {
        const [bu, bc, fr] = await Promise.all([
          supabase.rpc("mod_banned_users_list"),
          supabase.rpc("mod_banned_chats_list"),
          supabase.rpc("mod_flagging_revoked_list"),
        ]);
        const e = [bu, bc, fr].find((r) => r.error);
        if (e?.error) throw e.error;
        return json({
          bannedUsers: bu.data ?? [], bannedChats: bc.data ?? [],
          flaggingRevoked: fr.data ?? [],
        });
      }
      case "transparency": {
        const { data, error } = await supabase.rpc("metrics_transparency");
        if (error) throw error;
        return json({ transparency: data ?? [] });
      }

      // ---------- moderation actions ----------
      case "ban":
      case "unban": {
        if (req.method !== "POST") return json({ error: "POST required" }, 405);
        const body = await readBody();
        const kind = body.type; // 'user' | 'group'
        if (!body.id || (kind !== "user" && kind !== "group")) {
          return json({ error: "expected { type: 'user'|'group', id }" }, 400);
        }
        const fn = action === "ban"
          ? (kind === "user" ? "mod_ban_user" : "mod_ban_chat")
          : (kind === "user" ? "mod_unban_user" : "mod_unban_chat");
        const arg = kind === "user"
          ? { p_user: body.id, p_by } : { p_chat: body.id, p_by };
        const { error } = await supabase.rpc(fn, arg);
        if (error) throw error;
        return json({ ok: true });
      }
      case "resolve": {
        if (req.method !== "POST") return json({ error: "POST required" }, 405);
        const body = await readBody();
        if (!body.report_id || !body.resolution) {
          return json({ error: "expected { report_id, resolution }" }, 400);
        }
        const { error } = await supabase.rpc("mod_resolve_report", {
          p_report_id: body.report_id, p_resolution: body.resolution, p_by,
        });
        if (error) throw error;
        return json({ ok: true });
      }
      case "restore_flagging": {
        if (req.method !== "POST") return json({ error: "POST required" }, 405);
        const body = await readBody();
        if (!body.user_id) return json({ error: "expected { user_id }" }, 400);
        const { error } = await supabase.rpc("mod_restore_flagging", {
          p_user: body.user_id, p_by,
        });
        if (error) throw error;
        return json({ ok: true });
      }

      // ---------- operators (admin) ----------
      case "operators": {
        const { data, error } = await supabase.rpc("admin_operators_list");
        if (error) throw error;
        return json({ operators: data ?? [] });
      }
      case "operator_add": {
        if (req.method !== "POST") return json({ error: "POST required" }, 405);
        // bootstrap: when no operator exists yet, the network secret alone can
        // create the first one (necessarily an admin so the panel is usable).
        const body = await readBody();
        if (!body.username || !body.password) {
          return json({ error: "expected { username, password, role? }" }, 400);
        }
        const role = isBootstrap ? "admin" : (body.role ?? "moderator");
        const { data, error } = await supabase.rpc("admin_operator_add", {
          p_username: body.username, p_password: body.password,
          p_role: role, p_by,
        });
        if (error) throw error;
        return json({ id: data });
      }
      case "operator_disable": {
        if (req.method !== "POST") return json({ error: "POST required" }, 405);
        const body = await readBody();
        if (!body.id || typeof body.disabled !== "boolean") {
          return json({ error: "expected { id, disabled }" }, 400);
        }
        const { error } = await supabase.rpc("admin_operator_set_disabled", {
          p_id: body.id, p_disabled: body.disabled, p_by,
        });
        if (error) throw error;
        return json({ ok: true });
      }
      case "operator_set_role": {
        if (req.method !== "POST") return json({ error: "POST required" }, 405);
        const body = await readBody();
        if (!body.id || !body.role) return json({ error: "expected { id, role }" }, 400);
        const { error } = await supabase.rpc("admin_operator_set_role", {
          p_id: body.id, p_role: body.role, p_by,
        });
        if (error) throw error;
        return json({ ok: true });
      }
      case "operator_set_password": {
        if (req.method !== "POST") return json({ error: "POST required" }, 405);
        const body = await readBody();
        if (!body.id || !body.password) {
          return json({ error: "expected { id, password }" }, 400);
        }
        const { error } = await supabase.rpc("admin_operator_set_password", {
          p_id: body.id, p_password: body.password, p_by,
        });
        if (error) throw error;
        return json({ ok: true });
      }

      // ---------- settings (admin) ----------
      case "settings": {
        const { data, error } = await supabase.rpc("admin_settings_get");
        if (error) throw error;
        return json({ settings: data ?? [] });
      }
      case "settings_set": {
        if (req.method !== "POST") return json({ error: "POST required" }, 405);
        const body = await readBody();
        if (!body.key || body.value === undefined) {
          return json({ error: "expected { key, value }" }, 400);
        }
        const { error } = await supabase.rpc("admin_settings_set", {
          p_key: body.key, p_value: body.value, p_by,
        });
        if (error) throw error;
        return json({ ok: true });
      }

      // ---------- watchlists (admin) ----------
      case "lists": {
        const { data, error } = await supabase.rpc("moderation_lists_list");
        if (error) throw error;
        return json({ lists: data ?? [] });
      }
      case "list_terms": {
        const listId = url.searchParams.get("list_id");
        if (!listId) return json({ error: "expected ?list_id" }, 400);
        const { data, error } = await supabase.rpc("moderation_list_terms", {
          p_list_id: listId,
        });
        if (error) throw error;
        return json({ terms: data ?? [] });
      }
      case "list_add": {
        if (req.method !== "POST") return json({ error: "POST required" }, 405);
        const body = await readBody();
        if (!body.name) return json({ error: "expected { name }" }, 400);
        const { data, error } = await supabase.rpc("moderation_list_add", {
          p_name: body.name, p_description: body.description ?? null,
          p_source: body.source ?? "custom", p_by,
        });
        if (error) throw error;
        return json({ id: data });
      }
      case "list_rename": {
        if (req.method !== "POST") return json({ error: "POST required" }, 405);
        const body = await readBody();
        if (!body.id || !body.name) return json({ error: "expected { id, name }" }, 400);
        const { error } = await supabase.rpc("moderation_list_rename", {
          p_id: body.id, p_name: body.name, p_description: body.description ?? null, p_by,
        });
        if (error) throw error;
        return json({ ok: true });
      }
      case "list_set_enabled": {
        if (req.method !== "POST") return json({ error: "POST required" }, 405);
        const body = await readBody();
        if (!body.id || typeof body.enabled !== "boolean") {
          return json({ error: "expected { id, enabled }" }, 400);
        }
        const { error } = await supabase.rpc("moderation_list_set_enabled", {
          p_id: body.id, p_enabled: body.enabled, p_by,
        });
        if (error) throw error;
        return json({ ok: true });
      }
      case "list_delete": {
        if (req.method !== "POST") return json({ error: "POST required" }, 405);
        const body = await readBody();
        if (!body.id) return json({ error: "expected { id }" }, 400);
        const { error } = await supabase.rpc("moderation_list_delete", {
          p_id: body.id, p_by,
        });
        if (error) throw error;
        return json({ ok: true });
      }
      case "term_add": {
        if (req.method !== "POST") return json({ error: "POST required" }, 405);
        const body = await readBody();
        if (!body.list_id || !body.pattern) {
          return json({ error: "expected { list_id, pattern, category? }" }, 400);
        }
        const { data, error } = await supabase.rpc("moderation_term_add", {
          p_list_id: body.list_id, p_pattern: body.pattern,
          p_category: body.category ?? "other", p_by,
        });
        if (error) throw error;
        return json({ id: data });
      }
      case "term_remove": {
        if (req.method !== "POST") return json({ error: "POST required" }, 405);
        const body = await readBody();
        if (!body.id) return json({ error: "expected { id }" }, 400);
        const { error } = await supabase.rpc("moderation_term_remove", {
          p_id: body.id, p_by,
        });
        if (error) throw error;
        return json({ ok: true });
      }
      case "list_export": {
        const listId = url.searchParams.get("list_id");
        if (!listId) return json({ error: "expected ?list_id" }, 400);
        const { data, error } = await supabase.rpc("moderation_list_export", {
          p_list_id: listId,
        });
        if (error) throw error;
        return json({ list: data });
      }
      case "list_import": {
        if (req.method !== "POST") return json({ error: "POST required" }, 405);
        const body = await readBody();
        const payload = body.payload ?? body; // accept raw or {payload}
        if (!payload || typeof payload !== "object") {
          return json({ error: "expected a list JSON payload" }, 400);
        }
        const { data, error } = await supabase.rpc("moderation_list_import", {
          p_payload: payload, p_by,
        });
        if (error) throw error;
        return json({ id: data });
      }

      // ---------- audit (admin) ----------
      case "audit": {
        const limit = Number(url.searchParams.get("limit") ?? "200");
        const { data, error } = await supabase.rpc("admin_audit_list", {
          p_limit: Number.isFinite(limit) ? limit : 200,
        });
        if (error) throw error;
        return json({ audit: data ?? [] });
      }

      default:
        return json({ error: `unknown action '${action}'` }, 400);
    }
  } catch (err) {
    return json({ error: String(err instanceof Error ? err.message : err) }, 500);
  }
}

// deno-lint-ignore no-explicit-any
export async function collectStats(supabase: any, bucket: string) {
  // Fire the RPCs concurrently; each returns { data, error }.
  const [
    signups,
    chats,
    blocks,
    reactions,
    pending,
    platformMix,
    trustAdoption,
    mediaTotals,
    mediaPending,
    mediaUnreferenced,
    mediaByKind,
    daily,
    activeUsers,
    retention,
    appVersions,
  ] = await Promise.all([
    supabase.rpc("metrics_signups", { p_bucket: bucket }),
    supabase.rpc("metrics_chats", { p_bucket: bucket }),
    supabase.rpc("metrics_blocks", { p_bucket: bucket }),
    supabase.rpc("metrics_reactions", { p_bucket: bucket }),
    supabase.rpc("metrics_pending_requests", { p_bucket: bucket }),
    supabase.rpc("metrics_platform_mix"),
    supabase.rpc("metrics_trust_adoption"),
    supabase.rpc("metrics_media_totals"),
    supabase.rpc("metrics_media_pending"),
    supabase.rpc("metrics_media_unreferenced"),
    supabase.rpc("metrics_media_by_kind"),
    supabase.rpc("metrics_daily_series", {
      p_metrics: ["messages_sent"],
    }),
    supabase.rpc("metrics_active_users"),
    supabase.rpc("metrics_retention"),
    // 00076. Deliberately NOT in the error check below: whoever runs an older schema
    // version (a self-hoster) does not have this function yet — and a missing rollout
    // statistic must not take down the whole dashboard.
    supabase.rpc("fleet_app_versions"),
  ]);

  const firstError = [
    signups, chats, blocks, reactions, pending, platformMix, trustAdoption,
    mediaTotals, mediaPending, mediaUnreferenced, mediaByKind, daily,
    activeUsers, retention,
  ].find((r) => r.error);
  if (firstError?.error) throw firstError.error;

  // media_* RPCs return a single-row table → unwrap to an object.
  const one = (r: { data: unknown }) =>
    Array.isArray(r.data) ? (r.data[0] ?? null) : r.data;

  return {
    bucket,
    signups: signups.data ?? [],
    chats: chats.data ?? [],
    blocks: blocks.data ?? [],
    reactions: reactions.data ?? [],
    pendingRequests: pending.data ?? [],
    platformMix: platformMix.data ?? [],
    trustAdoption: trustAdoption.data ?? [],
    activeUsers: activeUsers.data ?? [],
    retention: retention.data ?? [],
    // [] instead of an error when the function is missing — the panel then
    // shows "no data" and the rest of the overview stays up.
    appVersions: appVersions.error ? [] : (appVersions.data ?? []),
    media: {
      totals: one(mediaTotals),
      pending: one(mediaPending),
      unreferenced: one(mediaUnreferenced),
      byKind: mediaByKind.data ?? [],
    },
    messagesDaily: daily.data ?? [],
  };
}

// Only bind a port when run as the entry point (keeps the handler unit-testable).
if (import.meta.main) {
  serve(handler);
}
