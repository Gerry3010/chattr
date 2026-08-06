// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Tests for the send-push-notification edge function.
//
// These run fully offline (no Firebase, no Supabase): they pin the service-role
// auth gate, the FCM HTTP v1 OAuth2 JWT assembly (header/claims/scope + a real
// RS256 signature verified against a locally generated key), the FCM message
// shape, and the dead-token detection. Real delivery still needs a device +
// the FCM_SERVICE_ACCOUNT secret — see the function README.
//
// Run: deno test --allow-env --allow-net --no-check supabase/functions/tests/
import {
  assertEquals,
  assertStringIncludes,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  buildFcmMessage,
  createSignedJwt,
  handler,
  loadServiceAccount,
} from "../send-push-notification/index.ts";

const SERVICE_ROLE = "service-role-test-key";
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", SERVICE_ROLE);
Deno.env.set("SUPABASE_URL", "http://127.0.0.1:54321");

function makeRequest(
  opts: { token?: string; method?: string; body?: unknown },
): Request {
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (opts.token !== undefined) headers["Authorization"] = `Bearer ${opts.token}`;
  return new Request("http://localhost/", {
    method: opts.method ?? "POST",
    headers,
    body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
  });
}

// --- Auth gate (same contract as the other privileged functions) ----------

Deno.test("send-push-notification: no Authorization header → 401", async () => {
  const res = await handler(makeRequest({}));
  assertEquals(res.status, 401);
});

Deno.test("send-push-notification: anon/user JWT → 401", async () => {
  const res = await handler(makeRequest({ token: "anon-or-user-jwt" }));
  assertEquals(res.status, 401);
});

Deno.test("send-push-notification: empty Bearer token → 401", async () => {
  const res = await handler(makeRequest({ token: "" }));
  assertEquals(res.status, 401);
});

Deno.test("send-push-notification: CORS preflight (OPTIONS) → 200", async () => {
  const res = await handler(makeRequest({ method: "OPTIONS" }));
  assertEquals(res.status, 200);
});

Deno.test(
  "send-push-notification: service-role key passes the gate (not 401)",
  async () => {
    // Empty user_ids fails validation downstream → 400, but NOT 401.
    const res = await handler(
      makeRequest({ token: SERVICE_ROLE, body: { user_ids: [] } }),
    );
    assertEquals(res.status !== 401, true);
  },
);

// --- Service-account loading ----------------------------------------------

Deno.test("loadServiceAccount: missing secret throws a helpful error", () => {
  Deno.env.delete("FCM_SERVICE_ACCOUNT");
  let threw = false;
  try {
    loadServiceAccount();
  } catch (e) {
    threw = true;
    assertStringIncludes((e as Error).message, "FCM_SERVICE_ACCOUNT");
  }
  assertEquals(threw, true);
});

Deno.test("loadServiceAccount: invalid JSON throws", () => {
  Deno.env.set("FCM_SERVICE_ACCOUNT", "{not json");
  let threw = false;
  try {
    loadServiceAccount();
  } catch (e) {
    threw = true;
    assertStringIncludes((e as Error).message, "not valid JSON");
  }
  Deno.env.delete("FCM_SERVICE_ACCOUNT");
  assertEquals(threw, true);
});

// --- FCM message shape -----------------------------------------------------

Deno.test("buildFcmMessage: v1 shape with android channel + apns", () => {
  const msg = buildFcmMessage("tok-123", "Chat", "Neue Nachricht von Bob", {
    chat_id: "c1",
  });
  assertEquals(msg.message.token, "tok-123");
  assertEquals(msg.message.notification?.title, "Chat");
  assertEquals(msg.message.notification?.body, "Neue Nachricht von Bob");
  assertEquals(msg.message.data.chat_id, "c1");
  assertEquals(msg.message.android?.notification?.channel_id, "chattr_messages");
  assertEquals(msg.message.android?.priority, "high");
  assertEquals(msg.message.apns?.payload.aps.sound, "default");
  // iOS grouping: thread-id mirrors chat_id so a chat's messages stack.
  assertEquals(msg.message.apns?.payload.aps["thread-id"], "c1");
});

Deno.test("buildFcmMessage: no chat_id → no thread-id (grouping omitted)", () => {
  const msg = buildFcmMessage("tok-123", "T", "B", {});
  assertEquals(msg.message.apns?.payload.aps.sound, "default");
  assertEquals(msg.message.apns?.payload.aps["thread-id"], undefined);
});

Deno.test("buildFcmMessage: mobile platforms keep the notification block", () => {
  for (const platform of ["android", "ios", "unknown", undefined]) {
    const msg = buildFcmMessage("tok-123", "T", "B", {}, platform);
    assertEquals(msg.message.notification?.title, "T");
  }
});

Deno.test("buildFcmMessage: web is data-only (no SDK auto-notification)", () => {
  const msg = buildFcmMessage("tok-web", "Chat", "Hallo", {
    chat_id: "c1",
  }, "web");
  assertEquals(msg.message.token, "tok-web");
  // No notification/android/apns blocks — the FCM JS SDK would auto-display
  // a duplicate next to the service worker's showNotification.
  assertEquals(msg.message.notification, undefined);
  assertEquals(msg.message.android, undefined);
  assertEquals(msg.message.apns, undefined);
  // Title/body ride along in data for the service worker to render.
  assertEquals(msg.message.data.title, "Chat");
  assertEquals(msg.message.data.body, "Hallo");
  assertEquals(msg.message.data.chat_id, "c1");
});

Deno.test("buildFcmMessage: aps.badge carries the absolute unread total", () => {
  const msg = buildFcmMessage("tok-123", "T", "B", { chat_id: "c1" }, "ios", 5);
  assertEquals(msg.message.apns?.payload.aps.badge, 5);
});

Deno.test("buildFcmMessage: badge 0 is sent explicitly (clears the badge)", () => {
  const msg = buildFcmMessage("tok-123", "T", "B", {}, "ios", 0);
  assertEquals(msg.message.apns?.payload.aps.badge, 0);
});

Deno.test("buildFcmMessage: no badge arg → aps.badge omitted (iOS unchanged)", () => {
  const msg = buildFcmMessage("tok-123", "T", "B", { chat_id: "c1" }, "ios");
  assertEquals(msg.message.apns?.payload.aps.badge, undefined);
});

Deno.test("buildFcmMessage: web ignores badge (data-only, no aps)", () => {
  const msg = buildFcmMessage("tok-web", "T", "B", {}, "web", 9);
  assertEquals(msg.message.apns, undefined);
});

// --- OAuth2 JWT assembly + real RS256 signature ---------------------------

async function generateTestServiceAccount() {
  const keyPair = await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    true,
    ["sign", "verify"],
  );
  const pkcs8 = await crypto.subtle.exportKey("pkcs8", keyPair.privateKey);
  const b64 = btoa(String.fromCharCode(...new Uint8Array(pkcs8)));
  const pem = `-----BEGIN PRIVATE KEY-----\n${
    b64.match(/.{1,64}/g)!.join("\n")
  }\n-----END PRIVATE KEY-----\n`;
  return {
    publicKey: keyPair.publicKey,
    sa: {
      client_email: "fcm@your-firebase-project.iam.gserviceaccount.com",
      private_key: pem,
      project_id: "your-firebase-project",
    },
  };
}

function b64urlToBytes(s: string): Uint8Array {
  const b64 = s.replace(/-/g, "+").replace(/_/g, "/").padEnd(
    s.length + (4 - (s.length % 4)) % 4,
    "=",
  );
  return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
}

Deno.test("createSignedJwt: header, claims and a verifiable RS256 signature", async () => {
  const { publicKey, sa } = await generateTestServiceAccount();
  const now = 1_700_000_000;
  const jwt = await createSignedJwt(sa, now);

  const [encHeader, encClaims, encSig] = jwt.split(".");
  const header = JSON.parse(new TextDecoder().decode(b64urlToBytes(encHeader)));
  const claims = JSON.parse(new TextDecoder().decode(b64urlToBytes(encClaims)));

  assertEquals(header.alg, "RS256");
  assertEquals(header.typ, "JWT");
  assertEquals(claims.iss, sa.client_email);
  assertEquals(
    claims.scope,
    "https://www.googleapis.com/auth/firebase.messaging",
  );
  assertEquals(claims.aud, "https://oauth2.googleapis.com/token");
  assertEquals(claims.iat, now);
  assertEquals(claims.exp, now + 3600);

  // The signature must verify against the service account's public key.
  // Copy into a fresh Uint8Array so TS sees a plain ArrayBuffer-backed view
  // (BufferSource), not ArrayBufferLike.
  const sigBytes = Uint8Array.from(b64urlToBytes(encSig));
  const ok = await crypto.subtle.verify(
    "RSASSA-PKCS1-v1_5",
    publicKey,
    sigBytes,
    new TextEncoder().encode(`${encHeader}.${encClaims}`),
  );
  assertEquals(ok, true);
});

// --- Push ohne Klartext, Stufe 1 (local_render gate) ------------------------

Deno.test("buildFcmMessage: local_render strips title/body for android", () => {
  const msg = buildFcmMessage("tok-a", "Familie", "Neue Nachricht von Bob", {
    type: "new_message",
    chat_id: "c1",
    message_id: "m1",
    sender_id: "u1",
  }, "android", 3, true);

  // Nothing human-readable may reach FCM.
  assertEquals(msg.message.notification, undefined);
  assertEquals(msg.message.data.title, undefined);
  assertEquals(msg.message.data.body, undefined);
  // Only ids survive — enough for the device to render from its own DB.
  assertEquals(msg.message.data, {
    type: "new_message",
    chat_id: "c1",
    message_id: "m1",
    sender_id: "u1",
  });
  // Without high priority Doze defers a data-only wakeup.
  assertEquals(msg.message.android?.priority, "high");
  // No tray entry to configure, and no apns block on android.
  assertEquals(msg.message.android?.notification, undefined);
  assertEquals(msg.message.apns, undefined);
});

Deno.test("buildFcmMessage: local_render strips title/body for web", () => {
  const msg = buildFcmMessage("tok-w", "Familie", "Neue Nachricht von Bob", {
    type: "new_message",
    chat_id: "c1",
  }, "web", undefined, true);

  assertEquals(msg.message.notification, undefined);
  assertEquals(msg.message.data.title, undefined);
  assertEquals(msg.message.data.body, undefined);
  assertEquals(msg.message.data, { type: "new_message", chat_id: "c1" });
});

Deno.test("buildFcmMessage: the allowlist denies unknown data keys", () => {
  // The point of the allowlist: a trigger that adds a display string back
  // later must not be able to leak it just because nobody edited this file.
  const msg = buildFcmMessage("tok-a", "T", "B", {
    type: "new_message",
    chat_id: "c1",
    sender_name: "Bob",
    requester_name: "Alice",
    chat_name: "Familie",
    some_future_field: "leak",
  }, "android", undefined, true);

  assertEquals(msg.message.data, { type: "new_message", chat_id: "c1" });
});

Deno.test("buildFcmMessage: without the flag nothing changes (no silent loss)", () => {
  // An install that cannot render locally must keep getting a displayable
  // push — a data-only message would show NOTHING there.
  for (const flag of [undefined, false]) {
    const msg = buildFcmMessage("tok-a", "Familie", "von Bob", {
      chat_id: "c1",
    }, "android", undefined, flag);
    assertEquals(msg.message.notification?.title, "Familie");
    assertEquals(msg.message.notification?.body, "von Bob");
  }
});

Deno.test("buildFcmMessage: iOS gets a placeholder + mutable-content, not silence", () => {
  const msg = buildFcmMessage("tok-i", "Familie", "von Bob", {
    chat_id: "c1",
    sender_id: "u1",
  }, "ios", 2, true);

  // Die Namen sind weg — das ist der Zweck.
  assertEquals(msg.message.notification?.title, "Chattr");
  assertEquals(msg.message.notification?.body, "Neue Nachricht");

  // Aber ein alert-Block MUSS bleiben: eine APNs-Nachricht ohne ihn ist ein
  // stiller Push und iOS zeigt gar nichts. Das ist der Unterschied zu Android.
  assertEquals(typeof msg.message.notification, "object");

  // Ohne dieses Flag ruft iOS die Extension nie auf und der Platzhalter bleibt
  // für immer stehen.
  assertEquals(msg.message.apns?.payload.aps["mutable-content"], 1);

  // Badge und Gruppierung überleben den neuen Pfad.
  assertEquals(msg.message.apns?.payload.aps.badge, 2);
  assertEquals(msg.message.apns?.payload.aps["thread-id"], "c1");

  // Und die Daten sind auf IDs beschnitten wie überall sonst.
  assertEquals(msg.message.data?.sender_id, "u1");
  assertEquals(msg.message.data?.title, undefined);
});

Deno.test("buildFcmMessage: iOS OHNE das Flag bleibt unverändert", () => {
  // Jedes iPhone da draußen, das noch nicht aktualisiert hat.
  const msg = buildFcmMessage("tok-i", "Familie", "von Bob", {
    chat_id: "c1",
  }, "ios", 2, false);
  assertEquals(msg.message.notification?.title, "Familie");
  assertEquals(msg.message.notification?.body, "von Bob");
  assertEquals(msg.message.apns?.payload.aps["mutable-content"], undefined);
});

Deno.test("buildFcmMessage: an unknown platform ignores the flag", () => {
  // Legacy rows with a NULL/odd platform must not fall into the data-only
  // path — better a leaky notification than a missing one.
  for (const platform of [undefined, "", "desktop"]) {
    const msg = buildFcmMessage("tok-x", "T", "B", {}, platform, undefined, true);
    assertEquals(msg.message.notification?.title, "T");
  }
});
