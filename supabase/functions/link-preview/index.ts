// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

// Link-preview proxy: fetches a page server-side and returns its OpenGraph
// metadata. Exists because (a) browsers CORS-block cross-origin page fetches,
// so the web/PWA client can't read og-tags itself, and (b) some sites
// (Reddit) reject non-browser user agents — a stable browser UA here is more
// reliable than whatever the mobile HTTP stack sends.
//
// Auth: the self-hosted edge runtime does NOT verify JWTs before invoking a
// function (found out the hard way — this used to be an open proxy), so the
// gate lives in here: callers must present the project apikey or a JWT that
// verifies against JWT_SECRET (every Supabase client sends both). SSRF: the
// target URL is restricted to http/https on public-looking hosts (no
// loopback/private/link-local IPs, no dotless Docker service names), the host
// is DNS-resolved and rejected if it points at a non-public address (closes
// nip.io/sslip.io-style bypasses), redirects are re-validated hop by hop, and
// the response body is capped.

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

const MAX_HTML_BYTES = 512 * 1024; // og tags live in <head>; 512 KiB is plenty
const FETCH_TIMEOUT_MS = 5_000;
const MAX_REDIRECTS = 5;
const BROWSER_UA =
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
  "(KHTML, like Gecko) Chrome/126.0 Safari/537.36";

function extract(html: string, property: string): string | undefined {
  // Handles both attribute orders: property=… content=… and content=… property=…
  const patterns = [
    new RegExp( // nosemgrep: detect-non-literal-regexp -- 'property' is a hardcoded literal (og:title etc.), not user input
      `<meta[^>]+(?:property|name)=["']${property}["'][^>]+content=["']([^"']+)`,
      "i",
    ),
    new RegExp( // nosemgrep: detect-non-literal-regexp -- 'property' is a hardcoded literal (og:title etc.), not user input
      `<meta[^>]+content=["']([^"']+)["'][^>]+(?:property|name)=["']${property}["']`,
      "i",
    ),
  ];
  for (const re of patterns) {
    const m = html.match(re);
    if (m) return decodeEntities(m[1].trim());
  }
  return undefined;
}

function decodeEntities(s: string): string {
  // Numeric character references — decimal (&#8211;) and hex (&#x2013;). Pages
  // encode spaces as &#x20; and dashes as &#x2013; etc.; without this they
  // showed up raw in the preview title. Guarded against invalid code points.
  const num = (code: number, whole: string): string => {
    if (!Number.isFinite(code) || code < 0 || code > 0x10ffff) return whole;
    try {
      return String.fromCodePoint(code);
    } catch {
      return whole;
    }
  };
  return s
    .replace(/&#x([0-9a-fA-F]+);/g, (m, h) => num(parseInt(h, 16), m))
    .replace(/&#(\d+);/g, (m, d) => num(parseInt(d, 10), m))
    .replaceAll("&lt;", "<")
    .replaceAll("&gt;", ">")
    .replaceAll("&quot;", '"')
    .replaceAll("&apos;", "'")
    .replaceAll("&nbsp;", " ")
    // &amp; last so "&amp;lt;" decodes to the literal "&lt;", not "<".
    .replaceAll("&amp;", "&");
}

// Reddit bot-walls the JSON API and (for plain browser UAs without JS) even
// the post pages, but serves link-preview crawlers a lightweight share page
// with og-tags — the same fetch Discord/Telegram/Slack previews make.
const CRAWLER_UA =
  "Mozilla/5.0 (compatible; Discordbot/2.0; +https://discordapp.com)";

// --- Auth gate --------------------------------------------------------------

function b64urlDecode(s: string): Uint8Array {
  const pad = "=".repeat((4 - s.length % 4) % 4);
  const b64 = s.replaceAll("-", "+").replaceAll("_", "/") + pad;
  return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
}

/// Verifies an HS256 JWT (Supabase user/anon/service tokens are all HS256
/// signed with the project's JWT_SECRET) including its expiry.
export async function verifyHs256Jwt(
  token: string,
  secret: string,
): Promise<boolean> {
  try {
    const [h, p, sig] = token.split(".");
    if (!h || !p || !sig) return false;
    const header = JSON.parse(new TextDecoder().decode(b64urlDecode(h)));
    if (header.alg !== "HS256") return false;
    const key = await crypto.subtle.importKey(
      "raw",
      new TextEncoder().encode(secret),
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["verify"],
    );
    const ok = await crypto.subtle.verify(
      "HMAC",
      key,
      b64urlDecode(sig),
      new TextEncoder().encode(`${h}.${p}`),
    );
    if (!ok) return false;
    const payload = JSON.parse(new TextDecoder().decode(b64urlDecode(p)));
    return typeof payload.exp !== "number" ||
      payload.exp > Date.now() / 1000;
  } catch {
    return false;
  }
}

/// Accepts the project apikey (anon/service) via `apikey` or Bearer header,
/// or any JWT that verifies against JWT_SECRET (user sessions).
export async function authorized(req: Request): Promise<boolean> {
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const jwtSecret = Deno.env.get("JWT_SECRET") ?? "";
  const apikey = req.headers.get("apikey") ?? "";
  const bearer = (req.headers.get("Authorization") ?? "")
    .replace(/^Bearer\s+/i, "");
  for (const k of [apikey, bearer]) {
    if (k && (k === anonKey || k === serviceKey) && (anonKey || serviceKey)) {
      return true;
    }
  }
  if (bearer && jwtSecret) return await verifyHs256Jwt(bearer, jwtSecret);
  return false;
}

// --- SSRF guard --------------------------------------------------------------

function isPrivateIpv4(host: string): boolean {
  const m = host.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
  if (!m) return false;
  const [a, b] = [Number(m[1]), Number(m[2])];
  if ([m[1], m[2], m[3], m[4]].some((o) => Number(o) > 255)) return true;
  return a === 0 || a === 10 || a === 127 ||
    (a === 100 && b >= 64 && b <= 127) ||
    (a === 169 && b === 254) ||
    (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && b === 168) ||
    (a === 192 && b === 0) ||
    (a === 198 && (b === 18 || b === 19)) ||
    a >= 224;
}

/// Rejects targets that could reach loopback, private ranges or
/// Docker-internal services (dotless hostnames like `supabase-kong`).
/// IPv6 literals are rejected wholesale — no legitimate shared link needs
/// one, and range-checking them correctly is not worth the risk.
export function isForbiddenTarget(url: URL): boolean {
  const host = url.hostname.toLowerCase();
  if (host.includes(":") || host.startsWith("[")) return true; // IPv6 literal
  if (!host.includes(".")) return true; // localhost, docker service names
  if (
    host.endsWith(".localhost") || host.endsWith(".local") ||
    host.endsWith(".internal") || host.endsWith(".lan") ||
    host.endsWith(".home.arpa")
  ) return true;
  return isPrivateIpv4(host);
}

/// True if `ip` (a resolved literal) is NOT globally routable — covers IPv6
/// loopback/ULA/link-local/multicast and IPv4-mapped IPv6, delegating IPv4 to
/// isPrivateIpv4. Unparseable input fails closed (treated as non-public).
export function ipNonPublic(ip: string): boolean {
  const s = ip.trim().toLowerCase();
  const mapped = s.match(/^::ffff:(\d{1,3}(?:\.\d{1,3}){3})$/); // IPv4-mapped
  if (mapped) return isPrivateIpv4(mapped[1]);
  if (s.includes(":")) {
    if (s === "::1" || s === "::") return true; // loopback / unspecified
    if (/^f[cd]/.test(s)) return true; // ULA fc00::/7
    if (/^fe[89ab]/.test(s)) return true; // link-local fe80::/10
    if (/^ff/.test(s)) return true; // multicast ff00::/8
    return false;
  }
  // Must be a well-formed dotted-quad; anything else fails closed (refuse).
  if (!/^\d{1,3}(?:\.\d{1,3}){3}$/.test(s)) return true;
  return isPrivateIpv4(s);
}

/// Resolve a hostname to A + AAAA records. Prefers the native resolver; falls
/// back to DNS-over-HTTPS (plain fetch to Cloudflare's 1.1.1.1) when the edge
/// runtime doesn't expose Deno.resolveDns. The DoH request targets a literal
/// public IP, so it needs no guarding and can't recurse into this proxy.
async function resolveHost(hostname: string): Promise<string[]> {
  // deno-lint-ignore no-explicit-any
  const native = (globalThis as any).Deno?.resolveDns;
  if (typeof native === "function") {
    const out: string[] = [];
    for (const kind of ["A", "AAAA"]) {
      try {
        out.push(...(await native(hostname, kind)) as string[]);
      } catch { /* NODATA for this family is fine */ }
    }
    return out;
  }
  const out: string[] = [];
  for (const type of ["A", "AAAA"]) {
    try {
      const r = await fetch(
        `https://1.1.1.1/dns-query?name=${encodeURIComponent(hostname)}&type=${type}`,
        { headers: { accept: "application/dns-json" } },
      );
      if (!r.ok) continue;
      const j = await r.json();
      for (const ans of j.Answer ?? []) {
        // A=1, AAAA=28; skip CNAME/other answer types.
        if (ans.type === 1 || ans.type === 28) out.push(String(ans.data));
      }
    } catch { /* ignore, other family may still resolve */ }
  }
  return out;
}

/// Authoritative SSRF check: the string filters above can't see a public-looking
/// hostname whose DNS points inside the network (nip.io / sslip.io, or an
/// attacker's own A-record). Resolve it and refuse if resolution fails or ANY
/// resolved address is non-public. Residual: a sub-TTL DNS rebind between this
/// check and the fetch is not closed (the edge runtime offers no connect-to-IP
/// pinning), but the static-record bypass — the reported finding — is closed.
export async function assertResolvesPublic(hostname: string): Promise<void> {
  const addrs = await resolveHost(hostname);
  if (addrs.length === 0) throw new Error("forbidden target: unresolvable host");
  for (const ip of addrs) {
    if (ipNonPublic(ip)) throw new Error("forbidden target: non-public address");
  }
}

/// fetch() with redirects validated hop by hop (a public URL may redirect
/// into the internal network — Deno's automatic following would go there).
async function fetchGuarded(
  url: URL,
  headers: Record<string, string>,
  signal: AbortSignal,
): Promise<{ res: Response; finalUrl: URL }> {
  let current = url;
  for (let hop = 0; hop <= MAX_REDIRECTS; hop++) {
    if (isForbiddenTarget(current)) throw new Error("forbidden target");
    await assertResolvesPublic(current.hostname); // resolve + reject internal IPs
    const res = await fetch(current, {
      headers,
      signal,
      redirect: "manual",
    });
    if ([301, 302, 303, 307, 308].includes(res.status)) {
      const loc = res.headers.get("location");
      res.body?.cancel().catch(() => {});
      if (!loc) return { res, finalUrl: current };
      current = new URL(loc, current);
      if (current.protocol !== "http:" && current.protocol !== "https:") {
        throw new Error("forbidden target");
      }
      continue;
    }
    return { res, finalUrl: current };
  }
  throw new Error("too many redirects");
}

function isRedditHost(hostname: string): boolean {
  return hostname === "reddit.com" || hostname.endsWith(".reddit.com") ||
    hostname === "redd.it" || hostname === "v.redd.it";
}

/// og:video is only returned when it is an actual media stream — many sites
/// (YouTube included) put an HTML embed page there, which no video player
/// can open.
export function playableOgVideo(
  url: string | undefined,
  type: string | undefined,
): string | undefined {
  if (!url) return undefined;
  if (type?.startsWith("video/")) return url;
  if (/\.(mp4|webm|m3u8|mov)(\?|$)/i.test(url)) return url;
  return undefined;
}

/// Extracts the playable video (signed HLS playlist, video+audio muxed) and
/// poster image from a Reddit embed page (embed.reddit.com — served to plain
/// browser UAs, unlike www.reddit.com). Reddit's own og:video would be a
/// video-only DASH mp4; the <shreddit-player> src is what actually plays.
export function parseRedditEmbed(html: string): {
  image?: string;
  video?: string;
} {
  const player = html.match(/<shreddit-player[^>]*>/i)?.[0];
  let video = player?.match(/\ssrc="([^"]+)"/i)?.[1];
  const image = player?.match(/\sposter="([^"]+)"/i)?.[1];
  // Fallback: any HLS playlist URL in the page.
  video ??= html.match(
    /https:\/\/v\.redd\.it\/[^"'\s<\\]+HLSPlaylist\.m3u8[^"'\s<\\]*/i,
  )?.[0];
  return {
    image: image ? decodeEntities(image) : undefined,
    video: video ? decodeEntities(video) : undefined,
  };
}

/// Best-effort embed-page lookup for canonical /r/…/comments/… URLs (share
/// links must already be redirect-resolved by the caller). Returns {} on any
/// failure — the og-tag fallback still applies.
async function fetchRedditEmbed(postUrl: URL): Promise<{
  image?: string;
  video?: string;
}> {
  if (!postUrl.pathname.includes("/comments/")) return {};
  try {
    const embedUrl =
      `https://embed.reddit.com${postUrl.pathname}?embed=true`;
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);
    const res = await fetch(embedUrl, {
      headers: { "User-Agent": BROWSER_UA, "Accept": "text/html" },
      signal: controller.signal,
    });
    clearTimeout(timeout);
    if (!res.ok) {
      res.body?.cancel().catch(() => {});
      return {};
    }
    return parseRedditEmbed(await res.text());
  } catch {
    return {};
  }
}

/// Reddit's crawler share page prefixes titles with "From the <sub>
/// community on Reddit: …" — strip that down to the post title.
export function cleanRedditTitle(title: string): string {
  return title.replace(/^From the \S+ community on Reddit:\s*/i, "")
    .replace(/^"(.*)"$/s, "$1");
}

export async function handler(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (!(await authorized(req))) {
    return json({ error: "unauthorized" }, 401);
  }

  // POST with the address in a JSON body (CHAT-35): in the query string it
  // ended up in every access log on the way. GET stays for apps that predate
  // the change.
  let url: string | null = null;
  if (req.method === "POST") {
    try {
      const body = await req.json();
      url = typeof body?.url === "string" ? body.url : null;
    } catch {
      url = null;
    }
  } else {
    url = new URL(req.url).searchParams.get("url");
  }
  if (!url) {
    return json({ error: "missing url parameter" }, 400);
  }

  let target: URL;
  try {
    target = new URL(url);
  } catch {
    return json({ error: "invalid url" }, 400);
  }
  if (target.protocol !== "http:" && target.protocol !== "https:") {
    return json({ error: "unsupported scheme" }, 400);
  }
  if (isForbiddenTarget(target)) {
    return json({ error: "forbidden target" }, 400);
  }

  // YouTube gates plain page fetches behind consent pages, but its oEmbed
  // endpoint is public and stable — prefer it for title + thumbnail.
  const ytHosts = ["youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be"];
  if (ytHosts.includes(target.hostname)) {
    try {
      const o = await fetch(
        `https://www.youtube.com/oembed?url=${encodeURIComponent(target.toString())}&format=json`,
        { headers: { "User-Agent": BROWSER_UA } },
      );
      if (o.ok) {
        const j = await o.json();
        return json({
          title: j.title ?? null,
          description: j.author_name ?? null,
          image: j.thumbnail_url ?? null,
          // Clients play YouTube through the iframe player (id from the URL).
          video: null,
        });
      }
    } catch {
      // fall through to the generic page fetch
    }
  }

  try {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);
    // Reddit only serves og-tags (and follows /s/ share-link redirects) for
    // known link-preview crawlers; everything else gets a JS challenge page.
    const ua = isRedditHost(target.hostname) ? CRAWLER_UA : BROWSER_UA;
    // finalUrl: the URL after redirects — resolves Reddit share links
    // (/r/<sub>/s/<token>) to the canonical /comments/ post URL.
    const { res, finalUrl } = await fetchGuarded(
      target,
      { "User-Agent": ua, "Accept": "text/html" },
      controller.signal,
    );
    clearTimeout(timeout);

    const reddit = isRedditHost(finalUrl.hostname) ||
      isRedditHost(target.hostname);

    if (!res.ok && !reddit) {
      return json({ error: `upstream ${res.status}` }, 502);
    }

    // Read at most MAX_HTML_BYTES. Reddit bot-walls may deny the page fetch;
    // the post-JSON lookup below still works, so continue with empty html.
    const reader = res.ok ? res.body?.getReader() : undefined;
    if (!res.ok) res.body?.cancel().catch(() => {});
    let html = "";
    if (reader) {
      const decoder = new TextDecoder();
      let received = 0;
      while (received < MAX_HTML_BYTES) {
        const { done, value } = await reader.read();
        if (done) break;
        received += value.byteLength;
        html += decoder.decode(value, { stream: true });
      }
      reader.cancel().catch(() => {});
    }

    let title = extract(html, "og:title") ??
      html.match(/<title[^>]*>([^<]*)<\/title>/i)?.[1]?.trim();
    let image = extract(html, "og:image") ??
      extract(html, "twitter:image");
    let video = playableOgVideo(
      extract(html, "og:video:secure_url") ?? extract(html, "og:video:url") ??
        extract(html, "og:video"),
      extract(html, "og:video:type"),
    );

    // Reddit: the embed page carries the signed HLS URL (muxed audio) that
    // actually plays; og:video (video-only DASH) never wins over it.
    if (reddit) {
      const post = await fetchRedditEmbed(finalUrl);
      image = post.image ?? image;
      video = post.video ?? video;
      if (title) title = cleanRedditTitle(title);
    }

    // Resolve protocol-relative / relative image URLs against the page.
    if (image) {
      try {
        image = new URL(image, finalUrl).toString();
      } catch {
        image = undefined;
      }
    }

    return json({
      title: title ? decodeEntities(title) : null,
      description: extract(html, "og:description") ?? null,
      image: image ?? null,
      video: video ?? null,
    });
  } catch (e) {
    return json({ error: `fetch failed: ${e}` }, 502);
  }
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

if (import.meta.main) {
  serve(handler);
}
