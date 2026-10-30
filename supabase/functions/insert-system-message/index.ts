// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
// Same primitives as web_crypto/ (client-side JS bundle) — the wire format
// must match byte-for-byte so clients can decrypt system messages.
import { createMlKem768 } from "https://esm.sh/mlkem@2.7.0";
import { x25519 } from "https://esm.sh/@noble/curves@1.8.1/ed25519";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

interface RequestBody {
  chat_id: string;
  action: string;
  subject_id: string;
  subject_name: string;
  /// Optional second argument for actions that need more than a subject —
  /// currently the disappearing-messages TTL in seconds for `ttl_enabled`.
  /// Deliberately raw, so each client renders the duration in its own locale.
  detail?: string | null;
  // userId -> combined public-key blob {"x": b64(X25519 pub), "m": b64(ML-KEM-768 ek)}
  member_keys?: Record<string, string>;
}

/**
 * Rounds an envelope up to a fixed size grid — mirrors
 * `lib/core/crypto/envelope_padding.dart` and `mcp_server/src/crypto_port.ts`
 * (same bucket, same field, same wrapper cost; keep the three in step).
 *
 * System messages are the most guessable of all by length: the set of things
 * they can say is small and fixed ("… ist beigetreten", "… hat die Gruppe
 * verlassen"), so the size of the stored row nearly names the event. That is
 * exactly the metadata this project keeps out of the server's reach elsewhere.
 *
 * Carried in ONE unknown field instead of a new envelope version: every
 * implementation that reads an envelope ignores fields it does not know, while
 * an unknown *version* throws and loses the message. Filler is random so
 * Postgres' TOAST compression cannot squeeze it back out.
 */
const PAD_BUCKET = 256;
const PAD_WRAPPER_COST = 7; // ,"x":""
const PAD_ALPHABET =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

export function padEnvelope(envelopeJson: string, bucket = PAD_BUCKET): string {
  if (bucket <= 0) return envelopeJson;
  if (!envelopeJson.startsWith("{") || !envelopeJson.endsWith("}")) {
    return envelopeJson;
  }
  if (envelopeJson.length <= 2) return envelopeJson;

  let target = Math.ceil((envelopeJson.length + PAD_WRAPPER_COST) / bucket) *
    bucket;
  if (target - envelopeJson.length < PAD_WRAPPER_COST) target += bucket;

  const n = target - envelopeJson.length - PAD_WRAPPER_COST;
  const bytes = crypto.getRandomValues(new Uint8Array(n));
  let filler = "";
  for (let i = 0; i < n; i++) filler += PAD_ALPHABET[bytes[i] % PAD_ALPHABET.length];
  return `${envelopeJson.slice(0, -1)},"x":"${filler}"}`;
}

// Exported so the auth gate is unit-testable without binding a port; the
// server is only started when this module is run as the entry point.
export async function handler(req: Request): Promise<Response> {
  // Handle CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

  // Authorization: this function performs privileged, RLS-bypassing inserts and is
  // only meant to be called server-to-server by the `insert_system_message` DB
  // function, which authenticates with the service-role key. Reject any other
  // caller so a normal user/anon JWT cannot inject forged "system" messages.
  const authHeader = req.headers.get("Authorization") ?? "";
  const token = authHeader.replace(/^Bearer\s+/i, "");
  if (!serviceRoleKey || !sameSecret(token ?? '', serviceRoleKey)) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 401,
    });
  }

  try {
    const supabaseClient = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      serviceRoleKey,
      {
        auth: {
          autoRefreshToken: false,
          persistSession: false,
        },
      }
    );

    const body: RequestBody = await req.json();
    const { chat_id, action, subject_id, subject_name, detail } = body;

    let member_keys = body.member_keys;

    if (!member_keys) {
      // Fallback: load member public keys for the chat. Note: `chat_members`
      // contains only accepted members (pending ones live in
      // `pending_chat_members`), so there is no `accepted` column to filter on.
      const { data, error } = await supabaseClient
        .from("chat_members")
        .select("user_id, public_key")
        .eq("chat_id", chat_id);

      if (error) {
        throw error;
      }

      member_keys = Object.fromEntries(
        (data ?? []).map((member) => [member.user_id, member.public_key])
      );
    }

    // Only the action and the recipient COUNT. Logging chat_id, subject_id,
    // subject_name and member_keys here dumped a chat's full membership list
    // into the log — right next to the code that is encrypting the message so
    // the server can't read it. These logs are persisted to Postgres and are
    // not pruned, so they outlive both the message and the account.
    console.log(
      `Insert system message: action=${action}, ` +
        `recipients=${Object.keys(member_keys ?? {}).length}`,
    );


    // Generate a single message ID for all recipient copies
    const messageId = crypto.randomUUID();
    const now = new Date().toISOString();

    // Mirror the client's KEM-DEM scheme (MessageEncryptionService v4): one
    // ephemeral AES-256 message key + a single AES-GCM ciphertext shared by
    // all recipients; only the hybrid-wrapped key differs per recipient.
    // v4 binds the ciphertext to (chat, sender, message) via AAD — system
    // messages are authored under the fixed 'system' sender (audit M3). They
    // carry no `sig`: they are server-generated, and clients exempt system
    // messages from the user-identity signature check (audit H1).
    // `detail` is only added when the action actually carries one, so the
    // payload for every pre-existing action stays byte-identical.
    const plaintext = new TextEncoder().encode(
      JSON.stringify(
        detail == null
          ? { action, subject_id, subject_name }
          : { action, subject_id, subject_name, detail },
      ),
    );
    const dataKey = crypto.getRandomValues(new Uint8Array(32));
    const aad = aadBytes(chat_id, "system", messageId);
    const msgB64 = toB64(await aesGcmEncrypt(dataKey, plaintext, aad));

    // v3 recipients (clients not yet on v4) can't use the AAD-bound v4
    // ciphertext, so they get their own no-AAD copy — built lazily, once.
    let legacyDataKey: Uint8Array | null = null;
    let legacyMsgB64: string | null = null;

    // Prepare message rows for batch insert
    const messageRows = [];

    for (const [userId, publicKeyCombined] of Object.entries(member_keys ?? {})) {
      // (was: log each recipient id — one persisted membership record per
      // member, per system message)

      try {
        // Combined blob {"x": b64, "m": b64} — X25519 + ML-KEM-768 public keys.
        const keys = JSON.parse(publicKeyCombined ?? "");
        const xPub = fromB64(keys.x);
        const mPub = fromB64(keys.m);
        if (mPub.length !== MLKEM768_EK_SIZE) {
          // No usable ML-KEM part (extinct X25519-only) — skip this member.
          console.error(`Skipping ${userId}: no valid ML-KEM key`);
          continue;
        }

        // Per-recipient version gate (P0 rollout safety): send v4 ONLY to a
        // recipient whose KEM key is identity-signed (`"s"`) — only v4 clients
        // sign. A v3 client that receives a v4 system message loses it
        // permanently (watermark advances past the undecryptable row). So
        // unsigned recipients get a v3 copy (no AAD, no scheme byte), which
        // their client reads fine. Fail-safe = v3.
        const recipientRunsV4 = typeof keys.s === "string";

        let encryptedContent: string;
        if (recipientRunsV4) {
          const ekRaw = await encryptDataKey(dataKey, xPub, mPub);
          const ek = new Uint8Array(1 + ekRaw.length);
          ek[0] = KEM_SCHEME_HYBRID;
          ek.set(ekRaw, 1);
          encryptedContent = padEnvelope(JSON.stringify({
            v: 4,
            alg: "hybrid-kem:aes-gcm",
            ek: toB64(ek),
            msg: msgB64,
          }));
        } else {
          if (!legacyDataKey) {
            legacyDataKey = crypto.getRandomValues(new Uint8Array(32));
            legacyMsgB64 = toB64(await aesGcmEncrypt(legacyDataKey, plaintext));
          }
          const ek = await encryptDataKey(legacyDataKey, xPub, mPub);
          encryptedContent = padEnvelope(JSON.stringify({
            v: 3,
            alg: "hybrid-kem:aes-gcm",
            ek: toB64(ek),
            msg: legacyMsgB64,
          }));
        }

        messageRows.push({
          id: messageId,
          chat_id,
          sender_id: null, // System messages have no sender
          recipient_id: userId,
          encrypted_content: encryptedContent,
          message_type: "system",
          created_at: now,
        });
      } catch (error) {
        console.error(
          `Failed to encrypt message for user ${userId}:`,
          error
        );
        // Skip this member if encryption fails (e.g. no published key yet)
        continue;
      }
    }

    // Batch insert all encrypted copies
    if (messageRows.length > 0) {
      const { error } = await supabaseClient.from("messages").insert(messageRows);

      if (error) {
        throw error;
      }
    }

    return new Response(
      JSON.stringify({ success: true, message_id: messageId }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200,
      }
    );
  } catch (error) {
    console.error("Error in insert-system-message:", error);
    return new Response(JSON.stringify({ error: (error as Error).message }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 500,
    });
  }
}

if (import.meta.main) serve(handler);

// ── Hybrid KEM (X25519 + ML-KEM-768) ────────────────────────────────────────
// Byte-for-byte port of web_crypto/src/crypto/hybrid-kem.ts (which mirrors the
// native Go library). Wire format of the wrapped key:
//   ephemPub(32) || mlkemCT(1088) || nonce(12)+gcm(dataKey)+tag
// Recipients without a valid ML-KEM key get the legacy X25519-only format.

const X25519_PUB_LEN = 32;
const MLKEM768_CT_SIZE = 1088;
const MLKEM768_EK_SIZE = 1184;
const HKDF_INFO = new TextEncoder().encode("chattr-hybrid-kem-v1");

/** v4 envelope scheme byte: full hybrid X25519+ML-KEM-768 wrapped key. */
const KEM_SCHEME_HYBRID = 0x02;

/**
 * v4 AAD — mirrors lib/core/crypto/message_context.dart byte-for-byte:
 * utf8("chattr-msg-aad-v1") ‖ 0 ‖ utf8(chatId) ‖ 0 ‖ utf8(senderId) ‖ 0 ‖ utf8(messageId)
 */
function aadBytes(chatId: string, senderId: string, messageId: string): Uint8Array {
  const enc = new TextEncoder();
  const parts = [
    enc.encode("chattr-msg-aad-v1"),
    enc.encode(chatId),
    enc.encode(senderId),
    enc.encode(messageId),
  ];
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0) + parts.length - 1);
  let off = 0;
  parts.forEach((p, i) => {
    if (i > 0) out[off++] = 0;
    out.set(p, off);
    off += p.length;
  });
  return out;
}

// deno-lint-ignore no-explicit-any
let _mlkem: any = null;
async function getMlKem() {
  if (!_mlkem) _mlkem = await createMlKem768();
  return _mlkem;
}

function toB64(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s);
}

function fromB64(s: string): Uint8Array {
  return Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
}

/** AES-256-GCM, wire format nonce(12) || ciphertext+tag (matches client). */
async function aesGcmEncrypt(
  key: Uint8Array,
  plaintext: Uint8Array,
  aad?: Uint8Array,
): Promise<Uint8Array> {
  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    key as unknown as BufferSource,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt"],
  );
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const params: AesGcmParams = { name: "AES-GCM", iv: nonce };
  if (aad && aad.length > 0) params.additionalData = aad as unknown as BufferSource;
  const ct = await crypto.subtle.encrypt(
    params,
    cryptoKey,
    plaintext as unknown as BufferSource,
  );
  const out = new Uint8Array(12 + ct.byteLength);
  out.set(nonce);
  out.set(new Uint8Array(ct), 12);
  return out;
}

async function hkdfSha256(
  ikm: Uint8Array,
  info: Uint8Array,
  length: number,
): Promise<Uint8Array> {
  const baseKey = await crypto.subtle.importKey("raw", ikm as unknown as BufferSource, "HKDF", false, [
    "deriveBits",
  ]);
  const bits = await crypto.subtle.deriveBits(
    { name: "HKDF", hash: "SHA-256", salt: new Uint8Array(0), info: info as unknown as BufferSource },
    baseKey,
    length * 8,
  );
  return new Uint8Array(bits);
}

/** Wraps [dataKey] for a recipient (X25519-only fallback for invalid ML-KEM keys). */
async function encryptDataKey(
  dataKey: Uint8Array,
  recipX25519Pub: Uint8Array,
  recipMlkemPub: Uint8Array,
): Promise<Uint8Array> {
  const ephemPriv = x25519.utils.randomPrivateKey();
  const ephemPub = x25519.getPublicKey(ephemPriv);
  const sharedX25519 = x25519.getSharedSecret(ephemPriv, recipX25519Pub);

  if (recipMlkemPub.length !== MLKEM768_EK_SIZE) {
    // Legacy X25519-only: ephPub(32) || AES-GCM(dataKey) with the raw shared
    // secret as key (no HKDF).
    const encDataKey = await aesGcmEncrypt(sharedX25519, dataKey);
    const out = new Uint8Array(X25519_PUB_LEN + encDataKey.length);
    out.set(ephemPub, 0);
    out.set(encDataKey, X25519_PUB_LEN);
    return out;
  }

  const mlkem = await getMlKem();
  const [mlkemCT, sharedMLKEM] = await mlkem.encap(recipMlkemPub);
  if (mlkemCT.length !== MLKEM768_CT_SIZE) {
    throw new Error(`mlkem: unexpected ciphertext size ${mlkemCT.length}`);
  }

  const ikm = new Uint8Array(sharedX25519.length + sharedMLKEM.length);
  ikm.set(sharedX25519);
  ikm.set(sharedMLKEM, sharedX25519.length);
  const combined = await hkdfSha256(ikm, HKDF_INFO, 32);

  const encDataKey = await aesGcmEncrypt(combined, dataKey);
  const out = new Uint8Array(
    X25519_PUB_LEN + MLKEM768_CT_SIZE + encDataKey.length,
  );
  out.set(ephemPub, 0);
  out.set(mlkemCT, X25519_PUB_LEN);
  out.set(encDataKey, X25519_PUB_LEN + MLKEM768_CT_SIZE);
  return out;
}

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
