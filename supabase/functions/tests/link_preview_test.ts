// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Tests for the link-preview edge function's pure helpers: the Reddit
// embed-page extraction (playable HLS URL + poster), the crawler-title
// cleanup and the og:video playability filter. The handler itself needs
// live upstream fetches, so it is smoke-tested against prod instead.
//
// Run: deno test --allow-env --allow-net --no-check supabase/functions/tests/
import {
  assertEquals,
  assertRejects,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  assertResolvesPublic,
  cleanRedditTitle,
  handler,
  ipNonPublic,
  isForbiddenTarget,
  parseRedditEmbed,
  playableOgVideo,
  verifyHs256Jwt,
} from "../link-preview/index.ts";

const ANON = "anon-test-key";
const JWT_SECRET = "super-secret-jwt-token-with-at-least-32-characters";
Deno.env.set("SUPABASE_ANON_KEY", ANON);
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "service-test-key");
Deno.env.set("JWT_SECRET", JWT_SECRET);

function b64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes))
    .replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

async function makeJwt(
  payload: Record<string, unknown>,
  secret = JWT_SECRET,
): Promise<string> {
  const enc = new TextEncoder();
  const h = b64url(enc.encode(JSON.stringify({ alg: "HS256", typ: "JWT" })));
  const p = b64url(enc.encode(JSON.stringify(payload)));
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = new Uint8Array(
    await crypto.subtle.sign("HMAC", key, enc.encode(`${h}.${p}`)),
  );
  return `${h}.${p}.${b64url(sig)}`;
}

function req(url: string, headers: Record<string, string> = {}): Request {
  return new Request(
    `http://localhost/?url=${encodeURIComponent(url)}`,
    { headers },
  );
}

// --- POST body (CHAT-35) -------------------------------------------------------

Deno.test("handler: POST mit der Adresse im Body wird gelesen", async () => {
  // A loopback target answers 400 "forbidden target" without network I/O:
  // proof that the body was read (a missing url would be "missing url").
  const res = await handler(
    new Request("http://localhost/", {
      method: "POST",
      headers: { apikey: ANON, "Content-Type": "application/json" },
      body: JSON.stringify({ url: "http://127.0.0.1:8000/" }),
    }),
  );
  assertEquals(res.status, 400);
  assertEquals((await res.json()).error, "forbidden target");
});

Deno.test("handler: POST ohne url → 400 missing url", async () => {
  const res = await handler(
    new Request("http://localhost/", {
      method: "POST",
      headers: { apikey: ANON, "Content-Type": "application/json" },
      body: "{}",
    }),
  );
  assertEquals(res.status, 400);
  assertEquals((await res.json()).error, "missing url parameter");
});

// --- auth gate ---------------------------------------------------------------

Deno.test("handler: no credentials → 401", async () => {
  const res = await handler(req("https://example.com"));
  assertEquals(res.status, 401);
  await res.body?.cancel();
});

Deno.test("handler: wrong apikey → 401", async () => {
  const res = await handler(req("https://example.com", { apikey: "nope" }));
  assertEquals(res.status, 401);
  await res.body?.cancel();
});

Deno.test("handler: anon apikey passes the gate (forbidden target ⇒ 400 not 401)", async () => {
  // A loopback target proves the gate passed without any network I/O.
  const res = await handler(req("http://127.0.0.1:8000/", { apikey: ANON }));
  assertEquals(res.status, 400);
  await res.body?.cancel();
});

Deno.test("handler: anon key as Bearer passes the gate", async () => {
  const res = await handler(
    req("http://localhost/x", { Authorization: `Bearer ${ANON}` }),
  );
  assertEquals(res.status, 400);
  await res.body?.cancel();
});

Deno.test("handler: valid user JWT passes, expired JWT does not", async () => {
  const now = Math.floor(Date.now() / 1000);
  const valid = await makeJwt({ sub: "u1", role: "authenticated", exp: now + 60 });
  let res = await handler(
    req("http://10.0.0.1/", { Authorization: `Bearer ${valid}` }),
  );
  assertEquals(res.status, 400); // gate passed, SSRF guard hit
  await res.body?.cancel();

  const expired = await makeJwt({ sub: "u1", exp: now - 60 });
  res = await handler(
    req("https://example.com", { Authorization: `Bearer ${expired}` }),
  );
  assertEquals(res.status, 401);
  await res.body?.cancel();
});

Deno.test("verifyHs256Jwt: rejects wrong secret and garbage", async () => {
  const foreign = await makeJwt({ sub: "u1" }, "some-other-secret-value-123456");
  assertEquals(await verifyHs256Jwt(foreign, JWT_SECRET), false);
  assertEquals(await verifyHs256Jwt("not.a.jwt", JWT_SECRET), false);
  assertEquals(await verifyHs256Jwt("", JWT_SECRET), false);
});

// --- SSRF guard ----------------------------------------------------------------

Deno.test("isForbiddenTarget: blocks loopback/private/internal hosts", () => {
  const blocked = [
    "http://localhost/",
    "http://foo.localhost/",
    "http://supabase-kong:8000/", // dotless docker service name
    "http://127.0.0.1/",
    "http://10.1.2.3/",
    "http://172.16.0.1/",
    "http://172.31.255.255/",
    "http://192.168.1.1/",
    "http://169.254.169.254/", // cloud metadata
    "http://100.64.0.1/",
    "http://0.0.0.0/",
    "http://[::1]/",
    "http://224.0.0.1/",
    "http://printer.local/",
    "http://gateway.internal/",
  ];
  for (const u of blocked) {
    assertEquals(isForbiddenTarget(new URL(u)), true, u);
  }
});

Deno.test("isForbiddenTarget: allows public hosts", () => {
  const allowed = [
    "https://www.reddit.com/r/x/comments/1/",
    "https://youtu.be/abc",
    "https://example.com/page",
    "https://93.184.216.34/", // public literal IPv4
    "https://172.15.0.1/", // just outside 172.16/12
    "https://172.32.0.1/",
  ];
  for (const u of allowed) {
    assertEquals(isForbiddenTarget(new URL(u)), false, u);
  }
});

// --- SSRF: DNS resolve guard (closes the nip.io/sslip.io string-check bypass) --

Deno.test("ipNonPublic: classifies resolved IPv4/IPv6 literals", () => {
  const nonPublic = [
    "169.254.169.254", // cloud metadata / link-local
    "127.0.0.1",
    "10.0.0.1",
    "172.16.0.1",
    "192.168.1.1",
    "100.64.0.1", // CGNAT
    "0.0.0.0",
    "224.0.0.1", // multicast
    "::1", // IPv6 loopback
    "fd00::1", // ULA
    "fe80::1", // link-local
    "ff02::1", // multicast
    "::ffff:127.0.0.1", // IPv4-mapped loopback
    "::ffff:169.254.169.254", // IPv4-mapped metadata
    "garbage", // unparseable → fail closed
  ];
  for (const ip of nonPublic) assertEquals(ipNonPublic(ip), true, ip);

  const publicIps = ["8.8.8.8", "1.1.1.1", "93.184.216.34", "2606:4700:4700::1111"];
  for (const ip of publicIps) assertEquals(ipNonPublic(ip), false, ip);
});

// Real DNS. This is the actual reported bypass: a public-looking hostname whose
// A-record points at an internal address. nip.io maps <ip>.nip.io → <ip>, so
// 169.254.169.254.nip.io resolves to the metadata address. The guard must
// reject it (either as non-public, or — if nip.io itself won't resolve — as
// unresolvable); both are a thrown "forbidden target".
Deno.test("assertResolvesPublic: rejects a public host pointing at an internal IP", async () => {
  await assertRejects(
    () => assertResolvesPublic("169.254.169.254.nip.io"),
    Error,
    "forbidden target",
  );
  await assertRejects(
    () => assertResolvesPublic("127.0.0.1.nip.io"),
    Error,
    "forbidden target",
  );
});

Deno.test("assertResolvesPublic: allows a genuinely public host", async () => {
  // Resolves to a public address → must NOT throw.
  await assertResolvesPublic("example.com");
});

// --- playableOgVideo -------------------------------------------------------

Deno.test("playableOgVideo: accepts video/* type", () => {
  assertEquals(
    playableOgVideo("https://cdn.example.com/clip", "video/mp4"),
    "https://cdn.example.com/clip",
  );
});

Deno.test("playableOgVideo: accepts media file extensions without type", () => {
  for (const url of [
    "https://x.com/a.mp4",
    "https://x.com/a.webm?sig=1",
    "https://x.com/a.m3u8",
  ]) {
    assertEquals(playableOgVideo(url, undefined), url);
  }
});

Deno.test("playableOgVideo: rejects HTML embed pages (YouTube og:video)", () => {
  assertEquals(
    playableOgVideo("https://www.youtube.com/embed/abc123", "text/html"),
    undefined,
  );
  assertEquals(
    playableOgVideo("https://www.youtube.com/embed/abc123", undefined),
    undefined,
  );
  assertEquals(playableOgVideo(undefined, "video/mp4"), undefined);
});

// --- parseRedditEmbed ------------------------------------------------------

Deno.test("parseRedditEmbed: extracts signed HLS src and poster", () => {
  // Attribute shape as served by embed.reddit.com (entity-encoded &).
  const html = `<html><body><shreddit-player class="x"
    src="https://v.redd.it/abc123/HLSPlaylist.m3u8?f=sd&amp;v=1&amp;a=1786372864%2CsIg"
    poster="https://external-preview.redd.it/pic.png?format=pjpg&amp;s=abc"
    preview="https://v.redd.it/abc123/CMAF_96.mp4"></shreddit-player></body></html>`;
  const parsed = parseRedditEmbed(html);
  assertEquals(
    parsed.video,
    "https://v.redd.it/abc123/HLSPlaylist.m3u8?f=sd&v=1&a=1786372864%2CsIg",
  );
  assertEquals(
    parsed.image,
    "https://external-preview.redd.it/pic.png?format=pjpg&s=abc",
  );
});

Deno.test("parseRedditEmbed: falls back to a bare playlist URL in the page", () => {
  const html =
    `<script>{"url":"https://v.redd.it/xyz/HLSPlaylist.m3u8?f=hd"}</script>`;
  assertEquals(
    parseRedditEmbed(html).video,
    "https://v.redd.it/xyz/HLSPlaylist.m3u8?f=hd",
  );
});

Deno.test("parseRedditEmbed: text/image posts have no video", () => {
  const html = `<html><body><shreddit-embed-copy-link-button>
    </shreddit-embed-copy-link-button><img src="https://i.redd.it/x.jpg">
    </body></html>`;
  const parsed = parseRedditEmbed(html);
  assertEquals(parsed.video, undefined);
  assertEquals(parsed.image, undefined);
});

// --- cleanRedditTitle ------------------------------------------------------

Deno.test("cleanRedditTitle: strips the crawler share-page prefix", () => {
  assertEquals(
    cleanRedditTitle(
      "From the oddlysatisfying community on Reddit: How mochi is made",
    ),
    "How mochi is made",
  );
  assertEquals(cleanRedditTitle("Plain title"), "Plain title");
});
