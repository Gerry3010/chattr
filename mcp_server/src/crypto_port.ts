// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Copyright (C) 2026 Gerald Hofbauer <info@geraldhofbauer.net>
// AGPLv3 — see <https://www.gnu.org/licenses/>.
//
// True 1:1 reuse (not a copy) of web_crypto/src/crypto/* — the same hybrid
// X25519 + ML-KEM-768 KEM used by the Flutter app and the
// insert-system-message Edge Function — plus the envelope-level
// ("hybrid-kem:aes-gcm", v3 legacy / v4 current) logic that mirrors
// lib/core/security/message_encryption_service.dart and
// lib/core/security/chat_key_pair_manager.dart byte-for-byte, so messages
// sent/received here are decryptable by (and readable from) real Chattr
// clients. Verified against web_crypto/testdata/interop_vector.json in
// test/crypto_interop.test.ts.
//
// v4 envelopes (audit H1/M3/H2) additionally:
//   • bind the DEM to its (chat, sender, message) context via AES-GCM AAD,
//   • prefix the wrapped key with scheme byte 0x02 and hard-reject anything
//     that isn't full hybrid KEM (no silent X25519-only downgrade),
//   • carry the sender's Ed25519 identity signature in `sig`.
// Byte layouts mirror lib/core/crypto/message_context.dart exactly.

import { encryptDataKey, decryptDataKey } from '../../web_crypto/src/crypto/hybrid-kem.js';
import { generateMLKEM768 } from '../../web_crypto/src/crypto/mlkem.js';
import { generateX25519 } from '../../web_crypto/src/crypto/x25519.js';
import { aesGcmEncrypt, aesGcmDecrypt } from '../../web_crypto/src/crypto/aes-gcm.js';

/** Mirrors ChatKeyPairManager's secure-storage record shape (base64 fields). */
export interface ChatKeyPair {
  xPriv: string;
  xPub: string;
  mPriv: string;
  mPub: string;
}

/** The combined blob written to chat_members.public_key / pending_chat_members.public_key. */
export interface PublicKeyBlob {
  x: string; // base64 X25519 public key
  m: string; // base64 ML-KEM-768 encapsulation (public) key
}

function toB64(bytes: Uint8Array): string {
  return Buffer.from(bytes).toString('base64');
}

function fromB64(s: string): Uint8Array {
  return new Uint8Array(Buffer.from(s, 'base64'));
}

/** Generates a fresh per-chat hybrid keypair — mirrors generateKeyPairForChat. */
export async function generateChatKeyPair(): Promise<ChatKeyPair> {
  const { priv: xPriv, pub: xPub } = generateX25519();
  const { priv: mPriv, pub: mPub } = await generateMLKEM768();
  return {
    xPriv: toB64(xPriv),
    xPub: toB64(xPub),
    mPriv: toB64(mPriv),
    mPub: toB64(mPub),
  };
}

/** The combined public-key blob object for a keypair. */
export function publicKeyBlob(pair: ChatKeyPair): PublicKeyBlob {
  return { x: pair.xPub, m: pair.mPub };
}

/** JSON-encoded public-key blob, ready to write to *.public_key columns. */
export function encodePublicKeyBlob(pair: ChatKeyPair): string {
  return JSON.stringify(publicKeyBlob(pair));
}

function randomAesKey(): Uint8Array {
  return crypto.getRandomValues(new Uint8Array(32));
}

// ── v4 message context (mirrors lib/core/crypto/message_context.dart) ──────

/** Scheme byte prefixed to a v4 `ek`: full hybrid X25519+ML-KEM-768. */
export const KEM_SCHEME_HYBRID = 0x02;

const MLKEM768_PUB_SIZE = 1184;
const MLKEM768_CT_SIZE_ = 1088;
/** ephemeral X25519 pub (32) + ML-KEM ct + AES-GCM nonce (12) + tag (16). */
const MIN_HYBRID_EK_LEN = 32 + MLKEM768_CT_SIZE_ + 12 + 16;

export interface MessageContext {
  chatId: string;
  senderId: string;
  messageId: string;
}

function joined(label: string, ctx: MessageContext, plaintext?: string): Uint8Array {
  const enc = new TextEncoder();
  const parts = [enc.encode(label), enc.encode(ctx.chatId), enc.encode(ctx.senderId), enc.encode(ctx.messageId)];
  if (plaintext !== undefined) parts.push(enc.encode(plaintext));
  const total = parts.reduce((n, p) => n + p.length, 0) + (parts.length - 1);
  const out = new Uint8Array(total);
  let off = 0;
  parts.forEach((p, i) => {
    if (i > 0) out[off++] = 0; // NUL separator
    out.set(p, off);
    off += p.length;
  });
  return out;
}

/** AAD for the AES-GCM DEM layer of a v4 envelope. */
export function aadBytes(ctx: MessageContext): Uint8Array {
  return joined('chattr-msg-aad-v1', ctx);
}

/** The exact bytes the sender's identity key signs for `plaintext`. */
export function signingBytes(ctx: MessageContext, plaintext: string): Uint8Array {
  return joined('chattr-msg-sig-v1', ctx, plaintext);
}

// ── Ed25519 identity key (mirrors lib/core/security/identity_key_manager.dart) ──

export interface IdentityKeyPair {
  /** base64 PKCS8 private key */
  privPkcs8: string;
  /** base64 raw 32-byte public key */
  pub: string;
}

export async function generateIdentityKeyPair(): Promise<IdentityKeyPair> {
  const kp = (await crypto.subtle.generateKey('Ed25519', true, ['sign', 'verify'])) as CryptoKeyPair;
  const pkcs8 = new Uint8Array(await crypto.subtle.exportKey('pkcs8', kp.privateKey));
  const raw = new Uint8Array(await crypto.subtle.exportKey('raw', kp.publicKey));
  return { privPkcs8: toB64(pkcs8), pub: toB64(raw) };
}

export async function signWithIdentity(pair: IdentityKeyPair, message: Uint8Array): Promise<string> {
  const key = await crypto.subtle.importKey(
    'pkcs8',
    fromB64(pair.privPkcs8) as unknown as BufferSource,
    'Ed25519',
    false,
    ['sign'],
  );
  const sig = await crypto.subtle.sign('Ed25519', key, message as unknown as BufferSource);
  return toB64(new Uint8Array(sig));
}

export async function verifyIdentitySignature(
  publicKeyB64: string,
  message: Uint8Array,
  signatureB64: string,
): Promise<boolean> {
  try {
    const key = await crypto.subtle.importKey(
      'raw',
      fromB64(publicKeyB64) as unknown as BufferSource,
      'Ed25519',
      false,
      ['verify'],
    );
    return await crypto.subtle.verify(
      'Ed25519',
      key,
      fromB64(signatureB64) as unknown as BufferSource,
      message as unknown as BufferSource,
    );
  } catch {
    return false; // fail closed on malformed inputs
  }
}

// ── KEM key ↔ identity binding (mirrors lib/core/security/kem_key_binding.dart) ──

const KEM_BINDING_LABEL = 'chattr-kem-identity-binding-v1';

/** The exact bytes an identity key signs to vouch for a public-key blob in a chat. */
export function kemBindingMessage(chatId: string, publicBlobJson: string): Uint8Array {
  const blob = JSON.parse(publicBlobJson) as PublicKeyBlob;
  const enc = new TextEncoder();
  const label = enc.encode(KEM_BINDING_LABEL);
  const chat = enc.encode(chatId);
  const x = fromB64(blob.x);
  const m = fromB64(blob.m);
  const out = new Uint8Array(label.length + chat.length + x.length + m.length);
  let off = 0;
  for (const p of [label, chat, x, m]) {
    out.set(p, off);
    off += p.length;
  }
  return out;
}

/** Returns `publicBlobJson` with the identity signature attached under `"s"`. */
export async function signPublicKeyBlob(
  identity: IdentityKeyPair,
  chatId: string,
  publicBlobJson: string,
): Promise<string> {
  const sig = await signWithIdentity(identity, kemBindingMessage(chatId, publicBlobJson));
  const blob = JSON.parse(publicBlobJson) as Record<string, unknown>;
  blob.s = sig;
  return JSON.stringify(blob);
}

// ── Envelope (v3 legacy / v4 current) ───────────────────────────────────────

/**
 * Encrypts `plaintext` ONCE (shared AES-256-GCM ciphertext) and wraps the
 * resulting message key separately for each recipient in `memberKeys`
 * (userId -> combined public-key blob JSON string). Mirrors
 * MessageEncryptionService.encryptForAllMembers: only the `ek` field differs
 * per recipient, `msg` is identical across all of them. With a `context`
 * this emits v4 (AAD-bound, hybrid-only, optionally signed); without one,
 * legacy v3. When a `recipientPrekeys` entry (a one-time prekey) is supplied
 * for a recipient, it emits v5 (forward secrecy): the message key is wrapped to
 * that ephemeral prekey and its id rides in `pk` — mirrors the Dart client. The
 * MCP agent publishes no prekeys, so at runtime this stays on v4/v3; the v5 path
 * exists for interop parity + a future prekey-backed agent.
 */
export async function encryptForAllMembers(
  plaintext: string,
  memberKeys: Record<string, string>,
  context?: MessageContext,
  signatureB64?: string,
  recipientPrekeys?: Record<string, { prekeyId: string; publicBlob: string }>,
): Promise<Record<string, string>> {
  const messageKey = randomAesKey();
  const aad = context ? aadBytes(context) : undefined;
  const msgBlob = await aesGcmEncrypt(messageKey, new TextEncoder().encode(plaintext), aad);
  const msgB64 = toB64(msgBlob);

  // Lazily-built v3 copy (own key + no-AAD ciphertext) for recipients we send
  // v3 to (X25519-only OR not yet on v4).
  let legacy: { key: Uint8Array; msgB64: string } | null = null;

  const out: Record<string, string> = {};
  for (const [userId, blobJson] of Object.entries(memberKeys)) {
    // Forward secrecy (v5): wrap to a claimed one-time prekey instead of the
    // static key. Same shared AAD ciphertext + signature as v4; only ek/pk
    // differ. Falls through to the v4/v3 gate below if no signed prekey.
    const pre = recipientPrekeys?.[userId];
    if (context && pre) {
      const preBlob = JSON.parse(pre.publicBlob) as PublicKeyBlob & { s?: string };
      const preM = fromB64(preBlob.m);
      if (preM.length === MLKEM768_PUB_SIZE && typeof preBlob.s === 'string') {
        const ekRaw = await encryptDataKey(messageKey, fromB64(preBlob.x), preM);
        const ek = new Uint8Array(1 + ekRaw.length);
        ek[0] = KEM_SCHEME_HYBRID;
        ek.set(ekRaw, 1);
        out[userId] = JSON.stringify({
          v: 5,
          alg: 'hybrid-kem:aes-gcm',
          ek: toB64(ek),
          pk: pre.prekeyId,
          msg: msgB64,
          ...(signatureB64 ? { sig: signatureB64 } : {}),
        });
        continue;
      }
    }

    const blob = JSON.parse(blobJson) as PublicKeyBlob & { s?: string };
    const mPub = fromB64(blob.m);

    if (!context) {
      const ek = await encryptDataKey(messageKey, fromB64(blob.x), mPub);
      out[userId] = JSON.stringify({ v: 3, alg: 'hybrid-kem:aes-gcm', ek: toB64(ek), msg: msgB64 });
      continue;
    }

    // Per-recipient version gate (P0 rollout safety): v4 ONLY to a recipient
    // whose KEM key is identity-signed (`s`) — only v4 clients sign. A v3 client
    // that receives v4 loses it permanently (watermark). Unsigned OR X25519-only
    // → v3 (which v4 clients read). Fail-safe = v3.
    const recipientRunsV4 = mPub.length === MLKEM768_PUB_SIZE && typeof blob.s === 'string';
    if (!recipientRunsV4) {
      if (!legacy) {
        const key = randomAesKey();
        legacy = { key, msgB64: toB64(await aesGcmEncrypt(key, new TextEncoder().encode(plaintext))) };
      }
      const ek = await encryptDataKey(legacy.key, fromB64(blob.x), mPub);
      out[userId] = JSON.stringify({ v: 3, alg: 'hybrid-kem:aes-gcm', ek: toB64(ek), msg: legacy.msgB64 });
      continue;
    }

    const ekRaw = await encryptDataKey(messageKey, fromB64(blob.x), mPub);
    const ek = new Uint8Array(1 + ekRaw.length);
    ek[0] = KEM_SCHEME_HYBRID;
    ek.set(ekRaw, 1);
    out[userId] = JSON.stringify({
      v: 4,
      alg: 'hybrid-kem:aes-gcm',
      ek: toB64(ek),
      msg: msgB64,
      ...(signatureB64 ? { sig: signatureB64 } : {}),
    });
  }
  return out;
}

/** Encrypts `plaintext` for a single recipient's combined public-key blob. */
export async function encryptForRecipient(
  plaintext: string,
  publicKeyBlobJson: string,
  context?: MessageContext,
  signatureB64?: string,
): Promise<string> {
  const result = await encryptForAllMembers(plaintext, { _: publicKeyBlobJson }, context, signatureB64);
  return result._;
}

interface Envelope {
  v: number;
  alg: string;
  ek: string;
  msg: string;
  sig?: string;
  /** v5 (forward secrecy): the one-time prekey id this envelope consumed. */
  pk?: string;
}

export interface DecryptedEnvelope {
  plaintext: string;
  version: number;
  signatureB64: string | null;
}

/**
 * Decrypts an envelope produced by encryptForAllMembers / a real Chattr
 * client. v4 requires `context` (AAD-bound) and rejects non-hybrid wrapped
 * keys (downgrade protection); v3 ignores the context.
 */
export async function decryptEnvelopeFull(
  envelopeJson: string,
  pair: ChatKeyPair,
  context?: MessageContext,
): Promise<DecryptedEnvelope> {
  const payload = JSON.parse(envelopeJson) as Envelope;
  if (payload.v !== 3 && payload.v !== 4 && payload.v !== 5) {
    throw new Error(`Unsupported envelope version ${payload.v} (expected 3, 4 or 5)`);
  }

  let ek = fromB64(payload.ek);
  let aad: Uint8Array | undefined;
  // v5 (forward secrecy) is identical to v4 on the wire except the wrapped key
  // targets a one-time prekey (named by `pk`) instead of the static chat key —
  // so `pair` must carry that prekey's private half. The MCP agent publishes no
  // prekeys, so senders' capability gate never emits v5 to it at runtime; this
  // branch exists for interop parity and for a future prekey-backed agent.
  if (payload.v === 4 || payload.v === 5) {
    if (!context) throw new Error(`v${payload.v} envelope needs a message context (AAD)`);
    if (ek.length === 0 || ek[0] !== KEM_SCHEME_HYBRID) {
      throw new Error(`v${payload.v} envelope with non-hybrid key scheme rejected`);
    }
    ek = ek.slice(1);
    if (ek.length < MIN_HYBRID_EK_LEN) {
      throw new Error(`v${payload.v} envelope with truncated hybrid key rejected`);
    }
    aad = aadBytes(context);
  }

  const messageKey = await decryptDataKey(ek, fromB64(pair.xPriv), fromB64(pair.mPriv));
  const plaintext = await aesGcmDecrypt(messageKey, fromB64(payload.msg), aad);
  return {
    plaintext: new TextDecoder().decode(plaintext),
    version: payload.v,
    signatureB64: typeof payload.sig === 'string' ? payload.sig : null,
  };
}

/** Back-compat plaintext-only variant of decryptEnvelopeFull. */
export async function decryptEnvelope(
  envelopeJson: string,
  pair: ChatKeyPair,
  context?: MessageContext,
): Promise<string> {
  return (await decryptEnvelopeFull(envelopeJson, pair, context)).plaintext;
}
