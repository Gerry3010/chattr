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
    "request_rejected" | "security_alert" | "call_invite" | "call_cancel";
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
    // `notification` is absent for a locally-rendered (data-only) push: with
    // no top-level notification there is no tray entry for it to configure.
    android?: {
      priority: string;
      ttl?: string;
      notification?: { channel_id: string };
    };
    apns?: {
      payload: {
        aps: {
          sound: string;
          "thread-id"?: string;
          badge?: number;
          /** 1 lässt iOS die Notification Service Extension aufrufen,
           *  die Titel und Text ersetzen darf, bevor sie erscheinen. */
          "mutable-content"?: number;
        };
      };
    };
  };
};

/** The only `data` keys that may leave the server for a locally-rendering
 * device. A deny-by-default allowlist, not a blocklist: a future trigger that
 * adds `sender_name` back (or any other display string) must not be able to
 * leak it just because nobody remembered to strip it here.
 *
 * These are opaque ids plus the notification kind — enough for the device to
 * look the names up in its own database. Correlatable by the push service,
 * which is what stage 3 addresses; the plaintext is what goes away here. */
/** Was iOS anzeigt, wenn die Notification Service Extension NICHT dazu kommt,
 *  den Text zu ersetzen — Zeitlimit, Speichermangel, Absturz. Muss deshalb für
 *  sich allein brauchbar sein und darf nichts verraten. Entspricht dem, was der
 *  Nutzer bei unbekanntem Absender ohnehin gesehen hätte. */
const IOS_PLACEHOLDER_TITLE = "Chattr";
const IOS_PLACEHOLDER_BODY = "Neue Nachricht";

const LOCAL_RENDER_DATA_KEYS = [
  "type",
  "chat_id",
  "message_id",
  "sender_id",
  "requester_id",
  // The coarse media category (image/video/audio/other), so the device can
  // build "X sent a photo". The trigger sets it ONLY when the recipient allows
  // it (profiles.push_media_kind, 00067) — the decision is therefore already
  // made there; all that stands here is that it may come through.
  "media_kind",
  // The reaction emoji ("X reacted with 👍"). Of all the keys here the only one
  // that is message CONTENT — which is why the trigger sets it only with the
  // recipient's explicit consent (profiles.push_reaction_emoji, 00072, default
  // OFF). If the switch is off, the key does not exist in the first place.
  "reaction",
] as const;

function stripToIds(data: Record<string, string>): Record<string, string> {
  const out: Record<string, string> = {};
  for (const key of LOCAL_RENDER_DATA_KEYS) {
    if (data[key] !== undefined) out[key] = data[key];
  }
  return out;
}

export function buildFcmMessage(
  token: string,
  title: string,
  body: string,
  data: Record<string, string>,
  platform?: string,
  badge?: number,
  localRender?: boolean,
): FcmMessage {
  // Push ohne Klartext, Stufe 1: this device renders the notification itself
  // from its local database, so neither the chat name nor the sender's
  // username needs to travel through Google. Only ids go out.
  //
  // Gated per device (`device_tokens.local_render`) rather than by platform
  // alone: a client that cannot render locally and gets a message with no
  // `notification` block shows NOTHING. Silent notification loss is the worst
  // possible failure here, so an older install keeps the old payload until it
  // updates and says otherwise.
  //
  // iOS takes a DIFFERENT route (see below): it cannot use a data-only push,
  // because APNs shows nothing without an alert block. It gets a placeholder
  // alert plus `mutable-content`, and its Notification Service Extension
  // rewrites the text before the user sees it.
  // A security alert carries no names and is a fixed sentence: it travels as
  // a plain notification even to devices that render locally (CHAT-37). The
  // local renderers know no "security_alert" and stay silent on unknown types
  // (Android, web) or keep the generic placeholder (iOS), so the warning that
  // someone recovered the account elsewhere never showed.
  const plainAlert = data.type === "security_alert";
  const renderLocally = !plainAlert && localRender === true &&
    (platform === "android" || platform === "web");

  // Stage 2 (iOS): the alert must travel — an APNs payload without one is a
  // silent push and iOS displays nothing at all. So instead of stripping the
  // notification, we send a PLACEHOLDER and let the extension replace it.
  //
  // The placeholder is deliberately a complete, usable sentence rather than
  // filler: the extension gets ~30 seconds and a tight memory budget, and if it
  // is killed or throws, iOS displays exactly this. "Neue Nachricht" is what
  // the user saw for an unknown sender anyway — never a debug string, never an
  // empty line.
  //
  // `mutable-content: 1` is what invokes the extension at all. Without it iOS
  // shows the placeholder and never calls our code.
  if (!plainAlert && localRender === true && platform === "ios") {
    return {
      message: {
        token,
        notification: { title: IOS_PLACEHOLDER_TITLE, body: IOS_PLACEHOLDER_BODY },
        data: stripToIds(data),
        apns: {
          payload: {
            aps: {
              "mutable-content": 1,
              sound: "default",
              ...(typeof data.chat_id === "string" && data.chat_id
                ? { "thread-id": data.chat_id }
                : {}),
              ...(typeof badge === "number" ? { badge } : {}),
            },
          },
        },
      },
    };
  }

  if (renderLocally) {
    return {
      message: {
        token,
        data: stripToIds(data),
        // No `notification` block — that is what routes the message to the
        // app's own handler instead of the OS tray. And no `android.
        // notification` either: without a top-level notification it would
        // describe a tray entry that never gets built. `priority: high` is
        // required, otherwise Doze defers the wakeup and the notification
        // arrives late or not at all.
        android: { priority: "high" },
      },
    };
  }

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
  localRender?: boolean,
): Promise<void> {
  const url = `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`;
  const res = await fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${accessToken}`,
    },
    body: JSON.stringify(
      buildFcmMessage(token, title, body, data, platform, badge, localRender),
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
// Calls (stage 3, migration 00088)
//
// A call push wakes a closed app so it can ring. It carries ids only —
// {type, chat_id, signal_id}: no caller, no name (Gerry, 2026-10-04). The
// sealed invite stays on the server (call_invites) until the device fetches
// it; it would not fit into a push anyway.
//
// Android: FCM, data-only, high priority, 30 s TTL — a call that rings a
// minute late is worse than one that never rings.
// iOS: NOT through FCM. A VoIP push must go straight to APNs with the
// PushKit token (platform 'ios_voip'), and iOS demands a CallKit call for
// every one of them — which is why the gates sit in send_call_signal.
// ---------------------------------------------------------------------------

export const CALL_PUSH_TYPES = ["call_invite", "call_cancel"] as const;

export function isCallPush(type: string | undefined): boolean {
  return (CALL_PUSH_TYPES as readonly string[]).includes(type ?? "");
}

/** Clients before this version do not know a call push — sent to them it
 *  would surface as a stray notification. Gated per DEVICE (app_version,
 *  00076), because one person's old tablet must not see it. */
export const CALL_PUSH_MIN_VERSION = "1.32.0";

export function versionAtLeast(v: string | null | undefined, min: string): boolean {
  if (!v) return false;
  const parse = (x: string) =>
    x.split(/[+-]/)[0].split(".").map((p) => parseInt(p, 10) || 0);
  const a = parse(v);
  const b = parse(min);
  for (let i = 0; i < 3; i++) {
    const x = a[i] ?? 0;
    const y = b[i] ?? 0;
    if (x !== y) return x > y;
  }
  return true;
}

const CALL_DATA_KEYS = ["type", "chat_id", "signal_id"] as const;

/** Deny-by-default, like stripToIds: a trigger that ever adds a name to a
 *  call push must not get it out through here. */
export function callData(data: Record<string, string>): Record<string, string> {
  const out: Record<string, string> = {};
  for (const key of CALL_DATA_KEYS) {
    if (data[key] !== undefined) out[key] = data[key];
  }
  return out;
}

export function buildCallFcmMessage(
  token: string,
  data: Record<string, string>,
): FcmMessage {
  return {
    message: {
      token,
      data: callData(data),
      android: { priority: "high", ttl: "30s" },
    },
  };
}

export type ApnsConfig = {
  keyP8: string;
  keyId: string;
  teamId: string;
  topic: string;
  host: string;
};

/** The APNs token key (.p8) and its ids. Null when not configured — then iOS
 *  is skipped and said so in the log, rather than failing Android too. */
export function loadApnsConfig(): ApnsConfig | null {
  const keyP8 = Deno.env.get("APNS_KEY_P8");
  const keyId = Deno.env.get("APNS_KEY_ID");
  const teamId = Deno.env.get("APNS_TEAM_ID");
  const topic = Deno.env.get("APNS_VOIP_TOPIC");
  if (!keyP8 || !keyId || !teamId || !topic) return null;
  return {
    keyP8,
    keyId,
    teamId,
    topic,
    host: Deno.env.get("APNS_HOST") || "api.push.apple.com",
  };
}

async function importEcPrivateKey(pem: string): Promise<CryptoKey> {
  const contents = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\\n/g, "")
    .replace(/\s/g, "");
  const der = Uint8Array.from(atob(contents), (c) => c.charCodeAt(0));
  return await crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
}

/** ES256 provider token for APNs. WebCrypto's ECDSA signature is already the
 *  raw r||s form JWT wants — no DER unwrapping. */
export async function createApnsJwt(
  cfg: ApnsConfig,
  nowSeconds: number,
): Promise<string> {
  const header = { alg: "ES256", kid: cfg.keyId };
  const claims = { iss: cfg.teamId, iat: nowSeconds };
  const signingInput = `${base64urlString(JSON.stringify(header))}.${
    base64urlString(JSON.stringify(claims))
  }`;
  const key = await importEcPrivateKey(cfg.keyP8);
  const sig = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(signingInput),
  );
  return `${signingInput}.${base64url(new Uint8Array(sig))}`;
}

// APNs rejects a provider token older than an hour and throttles one renewed
// more often than every 20 minutes; 50 minutes sits between.
let cachedApnsJwt: { jwt: string; issuedAt: number } | null = null;

async function getApnsJwt(cfg: ApnsConfig): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedApnsJwt && now - cachedApnsJwt.issuedAt < 50 * 60) {
    return cachedApnsJwt.jwt;
  }
  const jwt = await createApnsJwt(cfg, now);
  cachedApnsJwt = { jwt, issuedAt: now };
  return jwt;
}

export function buildVoipPayload(data: Record<string, string>) {
  return { aps: {}, chattr: callData(data) };
}

async function sendVoipPush(
  token: string,
  data: Record<string, string>,
  cfg: ApnsConfig,
): Promise<void> {
  const jwt = await getApnsJwt(cfg);
  const res = await fetch(`https://${cfg.host}/3/device/${token}`, {
    method: "POST",
    headers: {
      "authorization": `bearer ${jwt}`,
      "apns-push-type": "voip",
      "apns-topic": cfg.topic,
      "apns-priority": "10",
      "apns-expiration": String(Math.floor(Date.now() / 1000) + 30),
      "content-type": "application/json",
    },
    body: JSON.stringify(buildVoipPayload(data)),
  });
  if (!res.ok) {
    const text = await res.text();
    let reason: string | undefined;
    try {
      reason = JSON.parse(text)?.reason;
    } catch {
      // non-JSON
    }
    const err = new Error(`APNs ${res.status} ${reason ?? text}`) as
      & Error
      & { dead?: boolean; token?: string };
    err.dead = res.status === 410 || reason === "BadDeviceToken" ||
      reason === "Unregistered";
    err.token = token;
    throw err;
  }
}

async function sendFcmRaw(
  message: FcmMessage,
  accessToken: string,
  projectId: string,
): Promise<void> {
  const url = `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`;
  const res = await fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${accessToken}`,
    },
    body: JSON.stringify(message),
  });
  if (!res.ok) {
    const errorText = await res.text();
    let errorStatus: string | undefined;
    try {
      errorStatus = JSON.parse(errorText)?.error?.status;
    } catch {
      // non-JSON error body
    }
    const err = new Error(`FCM request failed: ${res.status}`) as
      & Error
      & { dead?: boolean; token?: string };
    err.dead = isDeadTokenStatus(res.status, errorStatus);
    err.token = message.message.token;
    throw err;
  }
}

type TokenRow = {
  token: string;
  platform: string;
  user_id: string;
  local_render: boolean | null;
  app_version: string | null;
};

/** Which devices a call push goes to, and how. Pure, so the routing rules
 *  are testable without FCM or APNs. Web never: it has no ringing when
 *  closed. iOS only through its VoIP token, never its regular one. */
export function routeCallPush(tokens: TokenRow[]): {
  fcm: TokenRow[];
  voip: TokenRow[];
} {
  return {
    fcm: tokens.filter((t) =>
      t.platform === "android" &&
      versionAtLeast(t.app_version, CALL_PUSH_MIN_VERSION)
    ),
    voip: tokens.filter((t) => t.platform === "ios_voip"),
  };
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
  if (!serviceRoleKey || !sameSecret(callerToken ?? '', serviceRoleKey)) {
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
      // `local_render` (migration 00065) decides per DEVICE whether this push
      // may go out without its plaintext title/body — see buildFcmMessage.
      .select("token, platform, user_id, local_render, app_version")
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

    if (isCallPush(payload.type)) {
      return await sendCallPushes(
        supabaseClient,
        tokens as TokenRow[],
        payload.data ?? {},
      );
    }

    // A VoIP token must never get an ordinary push (see routeCallPush).
    const regular = (tokens as TokenRow[]).filter((t) =>
      t.platform !== "ios_voip"
    );
    if (regular.length === 0) {
      return new Response(
        JSON.stringify({ success: true, message: "No tokens found", sent: 0 }),
        {
          headers: { ...corsHeaders, "Content-Type": "application/json" },
          status: 200,
        },
      );
    }

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
      regular.map(({ token, platform, user_id, local_render }) =>
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
          local_render === true,
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
          `Failed to send to token …${regular[index].token.slice(-6)}:`,
          result.reason,
        );
        if (reason?.dead) deadTokens.push(regular[index].token);
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
        total: regular.length,
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

async function sendCallPushes(
  // deno-lint-ignore no-explicit-any
  supabaseClient: any,
  tokens: TokenRow[],
  data: Record<string, string>,
): Promise<Response> {
  const { fcm, voip } = routeCallPush(tokens);
  const jobs: Promise<void>[] = [];

  if (fcm.length > 0) {
    const sa = loadServiceAccount();
    const projectId = Deno.env.get("FCM_PROJECT_ID") || sa.project_id;
    const accessToken = await getAccessToken(sa);
    for (const t of fcm) {
      jobs.push(
        sendFcmRaw(buildCallFcmMessage(t.token, data), accessToken, projectId),
      );
    }
  }
  const apns = voip.length > 0 ? loadApnsConfig() : null;
  if (voip.length > 0 && apns === null) {
    console.warn(`Call push: ${voip.length} iOS device(s) skipped, APNs not configured`);
  }
  if (apns) {
    for (const t of voip) jobs.push(sendVoipPush(t.token, data, apns));
  }

  const results = await Promise.allSettled(jobs);
  const dead: string[] = [];
  for (const r of results) {
    if (r.status === "rejected") {
      const reason = r.reason as { dead?: boolean; token?: string; message?: string };
      console.error(`Call push failed: ${reason?.message ?? "unknown"}`);
      if (reason?.dead && reason.token) dead.push(reason.token);
    }
  }
  if (dead.length > 0) {
    await supabaseClient.from("device_tokens").delete().in("token", dead);
  }
  const sent = results.filter((r) => r.status === "fulfilled").length;
  console.log(`Call push: sent ${sent}, failed ${results.length - sent}`);
  return new Response(
    JSON.stringify({ success: true, sent, failed: results.length - sent }),
    {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 200,
    },
  );
}

if (import.meta.main) serve(handler);

// Constant-time comparison of a presented secret with the expected one
// (CHAT-21): `!==` stops at the first differing character, and the time it
// takes says how much of a guess was right.
function sameSecret(presented: string, expected: string): boolean {
  const a = new TextEncoder().encode(presented);
  const b = new TextEncoder().encode(expected);
  let diff = a.length ^ b.length;
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    diff |= (a[i] ?? 0) ^ (b[i] ?? 0);
  }
  return diff === 0;
}
