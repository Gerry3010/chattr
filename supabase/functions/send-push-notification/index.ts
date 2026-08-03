// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

interface NotificationPayload {
  type: "new_message" | "member_request" | "request_accepted" |
    "request_rejected" | "security_alert";
  user_ids: string[];
  title: string;
  body: string;
  data?: Record<string, string>;
}

interface ServiceAccount {
  client_email: string;
  private_key: string;
  project_id: string;
  token_uri?: string;
}

// ---------------------------------------------------------------------------
// FCM HTTP v1 authentication.
//
// The v1 API (the only one Google still operates — the legacy /fcm/send API and
// its static "server keys" were removed in June 2024) authenticates with a
// short-lived OAuth2 access token minted from a Firebase *service account*, not
// a static key. We build & RS256-sign a JWT with the service account's private
// key, exchange it at Google's token endpoint for a `firebase.messaging`-scoped
// access token, and cache it until shortly before it expires.
// ---------------------------------------------------------------------------

const OAUTH_SCOPE = "https://www.googleapis.com/auth/firebase.messaging";
const DEFAULT_TOKEN_URI = "https://oauth2.googleapis.com/token";

let cachedToken: { accessToken: string; expiresAt: number } | null = null;

/** Reset the in-memory token cache (test seam). */
export function _resetTokenCache(): void {
  cachedToken = null;
}

export function loadServiceAccount(): ServiceAccount {
  const raw = Deno.env.get("FCM_SERVICE_ACCOUNT");
  if (!raw) {
    throw new Error(
      "FCM_SERVICE_ACCOUNT secret not configured (paste the full " +
        "service-account JSON from Firebase Console → Project Settings → " +
        "Service Accounts → Generate new private key)",
    );
  }
  let sa: ServiceAccount;
  try {
    sa = JSON.parse(raw);
  } catch {
    throw new Error("FCM_SERVICE_ACCOUNT is not valid JSON");
  }
  if (!sa.client_email || !sa.private_key || !sa.project_id) {
    throw new Error(
      "FCM_SERVICE_ACCOUNT is missing client_email, private_key or project_id",
    );
  }
  return sa;
}

function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function base64urlString(str: string): string {
  return base64url(new TextEncoder().encode(str));
}

async function importPrivateKey(pem: string): Promise<CryptoKey> {
  const contents = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\\n/g, "")
    .replace(/\s/g, "");
  const der = Uint8Array.from(atob(contents), (c) => c.charCodeAt(0));
  return await crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
}

/** Build a signed OAuth2 JWT assertion for the given service account. */
export async function createSignedJwt(
  sa: ServiceAccount,
  nowSeconds: number,
): Promise<string> {
  const header = { alg: "RS256", typ: "JWT" };
  const claims = {
    iss: sa.client_email,
    scope: OAUTH_SCOPE,
    aud: sa.token_uri ?? DEFAULT_TOKEN_URI,
    iat: nowSeconds,
    exp: nowSeconds + 3600,
  };
  const signingInput = `${base64urlString(JSON.stringify(header))}.${
    base64urlString(JSON.stringify(claims))
  }`;
  const key = await importPrivateKey(sa.private_key);
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(signingInput),
  );
  return `${signingInput}.${base64url(new Uint8Array(signature))}`;
}

async function getAccessToken(sa: ServiceAccount): Promise<string> {
  const nowSeconds = Math.floor(Date.now() / 1000);
  // Reuse a cached token until 60s before it expires.
  if (cachedToken && cachedToken.expiresAt > nowSeconds + 60) {
    return cachedToken.accessToken;
  }

  const jwt = await createSignedJwt(sa, nowSeconds);
  const res = await fetch(sa.token_uri ?? DEFAULT_TOKEN_URI, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: jwt,
    }),
  });

  if (!res.ok) {
    throw new Error(
      `OAuth token exchange failed: ${res.status} - ${await res.text()}`,
    );
  }

  const json = await res.json();
  cachedToken = {
    accessToken: json.access_token,
    expiresAt: nowSeconds + (json.expires_in ?? 3600),
  };
  return cachedToken.accessToken;
}

// ---------------------------------------------------------------------------
// FCM message
// ---------------------------------------------------------------------------

/** Shape the FCM HTTP v1 request body for a single device token.
 *
 * Web tokens get a DATA-ONLY message: with a `notification` block the FCM JS
 * SDK auto-displays a notification AND still invokes the service worker's
 * onBackgroundMessage (which calls showNotification with a different tag) —
 * the user saw every push twice. Data-only means only the service worker
 * renders it; title/body ride along in `data`. Mobile platforms keep the
 * `notification` block for OS tray display. */
export type FcmMessage = {
  message: {
    token: string;
    data: Record<string, string>;
    notification?: { title: string; body: string };
    android?: { priority: string; notification: { channel_id: string } };
    apns?: {
      payload: { aps: { sound: string; "thread-id"?: string; badge?: number } };
    };
  };
};

export function buildFcmMessage(
  token: string,
  title: string,
  body: string,
  data: Record<string, string>,
  platform?: string,
  badge?: number,
): FcmMessage {
  if (platform === "web") {
    return {
      message: {
        token,
        data: { ...data, title, body },
      },
    };
  }
  // Group iOS notifications by conversation: FCM passes `thread-id` through to
  // APNs → UNNotificationContent.threadIdentifier, so multiple messages from the
  // same chat stack under one thread instead of piling up as separate banners.
  // Keyed on the chat_id the notify triggers always include in `data`.
  const chatId = data["chat_id"];
  return {
    message: {
      token,
      notification: { title, body },
      data,
      android: {
        priority: "high",
        notification: { channel_id: "chattr_messages" },
      },
      apns: {
        // `aps.badge` = the recipient's ABSOLUTE total unread (incl. this
        // message), so iOS sets the app-icon badge correctly while the app is
        // backgrounded — without it running. Matches the client's
        // totalUnreadProvider (both derive from last_read_at, migrations
        // 00053/00054). Omitted (badge left unchanged by iOS) only when the
        // count is unknown; an explicit 0 clears the badge.
        payload: {
          aps: {
            sound: "default",
            ...(chatId ? { "thread-id": chatId } : {}),
            ...(typeof badge === "number" ? { badge } : {}),
          },
        },
      },
    },
  };
}

/** A token Google reports as permanently invalid → safe to delete from our DB. */
function isDeadTokenStatus(httpStatus: number, errorStatus?: string): boolean {
  // UNREGISTERED → app uninstalled / token rotated; INVALID_ARGUMENT on the
  // token field → malformed token. Both are unrecoverable for this token.
  return (
    httpStatus === 404 ||
    errorStatus === "UNREGISTERED" ||
    errorStatus === "INVALID_ARGUMENT"
  );
}

async function sendFCMNotification(
  token: string,
  title: string,
  body: string,
  data: Record<string, string>,
  accessToken: string,
  projectId: string,
  platform?: string,
  badge?: number,
): Promise<void> {
  const url = `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`;
  const res = await fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${accessToken}`,
    },
    body: JSON.stringify(
      buildFcmMessage(token, title, body, data, platform, badge),
    ),
  });

  if (!res.ok) {
    const errorText = await res.text();
    let errorStatus: string | undefined;
    try {
      errorStatus = JSON.parse(errorText)?.error?.status;
    } catch {
      // non-JSON error body
    }
    const err = new Error(
      `FCM request failed: ${res.status} - ${errorText}`,
    ) as Error & { dead?: boolean; token?: string };
    err.dead = isDeadTokenStatus(res.status, errorStatus);
    err.token = token;
    throw err;
  }
}

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

// Exported so the auth gate and orchestration are unit-testable without binding
// a port; the server is only started when this module is the entry point.
export async function handler(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

  // Authorization: this function blasts push notifications to arbitrary users
  // and is only meant to be called server-to-server by the DB trigger
  // (`notify_members_new_message`), which authenticates with the service-role
  // key. Reject any other caller so the public anon key cannot be used to spam
  // notifications.
  const authHeader = req.headers.get("Authorization") ?? "";
  const callerToken = authHeader.replace(/^Bearer\s+/i, "");
  if (!serviceRoleKey || callerToken !== serviceRoleKey) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 401,
    });
  }

  try {
    const payload: NotificationPayload = await req.json();
    // Deliberately NOT logging the payload: it carries the chat name, the
    // sender's username and the recipient ids. Vector ships these logs into
    // Postgres (_analytics) where nothing prunes them, so a debug line here
    // becomes a permanent plaintext social-graph record that even survives
    // account deletion. Counts only.
    console.log(
      `Notification request for ${payload.user_ids?.length ?? 0} user(s)`,
    );

    if (!payload.user_ids || payload.user_ids.length === 0) {
      throw new Error("user_ids is required and must not be empty");
    }

    const supabaseClient = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      serviceRoleKey,
      { auth: { autoRefreshToken: false, persistSession: false } },
    );

    const { data: tokens, error: tokensError } = await supabaseClient
      .from("device_tokens")
      .select("token, platform, user_id")
      .in("user_id", payload.user_ids);

    if (tokensError) {
      console.error("Error fetching tokens:", tokensError);
      throw tokensError;
    }

    if (!tokens || tokens.length === 0) {
      console.log(
        `No device tokens found for ${payload.user_ids.length} user(s)`,
      );
      return new Response(
        JSON.stringify({ success: true, message: "No tokens found", sent: 0 }),
        {
          headers: { ...corsHeaders, "Content-Type": "application/json" },
          status: 200,
        },
      );
    }

    console.log(`Found ${tokens.length} device tokens`);

    const sa = loadServiceAccount();
    const projectId = Deno.env.get("FCM_PROJECT_ID") || sa.project_id;
    const accessToken = await getAccessToken(sa);

    // Per-recipient total unread → each token's `aps.badge` (iOS icon badge
    // while backgrounded). Absolute value including the message that triggered
    // this push. Best-effort: on any RPC failure we send with no badge (iOS
    // leaves it unchanged) rather than fail the whole push.
    const badgeByUser = new Map<string, number>();
    try {
      const { data: totals, error: totalsError } = await supabaseClient.rpc(
        "unread_totals",
        { p_user_ids: payload.user_ids },
      );
      if (totalsError) {
        console.error("Error fetching unread totals:", totalsError);
      } else {
        for (const row of (totals ?? []) as
          { user_id: string; unread: number }[]) {
          badgeByUser.set(row.user_id, Number(row.unread) || 0);
        }
      }
    } catch (e) {
      console.error("unread_totals RPC threw:", e);
    }

    const results = await Promise.allSettled(
      tokens.map(({ token, platform, user_id }) =>
        sendFCMNotification(
          token,
          payload.title,
          payload.body,
          payload.data || {},
          accessToken,
          projectId,
          platform,
          // Users absent from the totals map have 0 unread → send 0 so a
          // lingering badge clears (only web tokens ignore it).
          platform === "web" ? undefined : (badgeByUser.get(user_id) ?? 0),
        )
      ),
    );

    const successful = results.filter((r) => r.status === "fulfilled").length;
    const failed = results.length - successful;

    // Collect tokens Google reports as permanently invalid and prune them so the
    // device_tokens table does not accumulate dead entries.
    const deadTokens: string[] = [];
    results.forEach((result, index) => {
      if (result.status === "rejected") {
        const reason = result.reason as { dead?: boolean };
        // Log a short digest instead of the full FCM token: the token is a
        // stable per-device identifier, and these logs are persisted.
        console.error(
          `Failed to send to token …${tokens[index].token.slice(-6)}:`,
          result.reason,
        );
        if (reason?.dead) deadTokens.push(tokens[index].token);
      }
    });

    if (deadTokens.length > 0) {
      const { error: deleteError } = await supabaseClient
        .from("device_tokens")
        .delete()
        .in("token", deadTokens);
      if (deleteError) {
        console.error("Failed to prune dead tokens:", deleteError);
      } else {
        console.log(`Pruned ${deadTokens.length} dead device tokens`);
      }
    }

    console.log(`Sent ${successful} notifications, ${failed} failed`);

    return new Response(
      JSON.stringify({
        success: true,
        sent: successful,
        failed,
        total: tokens.length,
        pruned: deadTokens.length,
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200,
      },
    );
  } catch (error) {
    console.error("Error in send-push-notification function:", error);
    const message = error instanceof Error ? error.message : String(error);
    return new Response(
      JSON.stringify({ success: false, error: message }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 400,
      },
    );
  }
}

if (import.meta.main) serve(handler);
