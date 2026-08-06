// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Copyright (C) 2026 Gerald Hofbauer <info@geraldhofbauer.net>
// AGPLv3 — see <https://www.gnu.org/licenses/>.
//
// Verifies crypto_port.ts against the fixed known-answer vector in
// web_crypto/testdata/interop_vector.json (the same vector the web bundle's
// own test.mjs partially exercises) — this MCP server's KEM wrap/unwrap
// must produce/consume byte-identical output to every other Chattr client.
// Also round-trips the full v3 envelope (KEM-level only in the fixture) and
// checks the public-key blob / keypair shapes match ChatKeyPairManager.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

import { decryptDataKey, encryptDataKey } from '../../web_crypto/src/crypto/hybrid-kem.js';
import {
  generateChatKeyPair,
  encryptForAllMembers,
  encryptForRecipient,
  decryptEnvelope,
  decryptEnvelopeFull,
  encodePublicKeyBlob,
  publicKeyBlob,
  generateIdentityKeyPair,
  signWithIdentity,
  verifyIdentitySignature,
  signPublicKeyBlob,
  kemBindingMessage,
  signingBytes,
  KEM_SCHEME_HYBRID,
  type MessageContext,
} from '../src/crypto_port.js';

// A recipient key marked v4-capable (identity-signed) so the per-recipient
// version gate emits v4. The gate only checks that "s" is present.
function v4Blob(pair: Parameters<typeof encodePublicKeyBlob>[0]): string {
  const blob = JSON.parse(encodePublicKeyBlob(pair));
  blob.s = 'v4-capable-sig';
  return JSON.stringify(blob);
}

// At runtime this file lives at build/mcp_server/test/ (see tsconfig.json's
// mirrored-root note) — four levels up is the chattr repo root.
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const vectorPath = path.join(__dirname, '../../../../web_crypto/testdata/interop_vector.json');
const vector = JSON.parse(readFileSync(vectorPath, 'utf8')) as Record<string, string>;

function fromB64(s: string): Uint8Array {
  return new Uint8Array(Buffer.from(s, 'base64'));
}

test('decrypts the fixed native-generated wrapped key (encNative) to the known dataKey', async () => {
  const dataKey = await decryptDataKey(fromB64(vector.encNative), fromB64(vector.x25519Priv), fromB64(vector.mlkemPriv));
  assert.deepEqual(new Uint8Array(dataKey), fromB64(vector.dataKey));
});

test('decrypts the fixed web-generated wrapped key (encWeb) to the known dataKey', async () => {
  const dataKey = await decryptDataKey(fromB64(vector.encWeb), fromB64(vector.x25519Priv), fromB64(vector.mlkemPriv));
  assert.deepEqual(new Uint8Array(dataKey), fromB64(vector.dataKey));
});

test('own wrap/unwrap round-trips the fixed dataKey', async () => {
  const wrapped = await encryptDataKey(fromB64(vector.dataKey), fromB64(vector.x25519Pub), fromB64(vector.mlkemPub));
  const unwrapped = await decryptDataKey(wrapped, fromB64(vector.x25519Priv), fromB64(vector.mlkemPriv));
  assert.deepEqual(new Uint8Array(unwrapped), fromB64(vector.dataKey));
});

test('generateChatKeyPair produces ChatKeyPairManager-shaped sizes (X25519 32/32, ML-KEM-768 1184/2400)', async () => {
  const pair = await generateChatKeyPair();
  assert.equal(fromB64(pair.xPub).length, 32);
  assert.equal(fromB64(pair.xPriv).length, 32);
  assert.equal(fromB64(pair.mPub).length, 1184);
  assert.equal(fromB64(pair.mPriv).length, 2400);
});

test('encodePublicKeyBlob matches the {"x":...,"m":...} shape written to chat_members.public_key', async () => {
  const pair = await generateChatKeyPair();
  const blob = JSON.parse(encodePublicKeyBlob(pair));
  assert.deepEqual(Object.keys(blob).sort(), ['m', 'x']);
  assert.equal(blob.x, publicKeyBlob(pair).x);
  assert.equal(blob.m, publicKeyBlob(pair).m);
});

test('full v3 envelope round-trip: encrypt for one recipient, decrypt back to the same plaintext', async () => {
  const pair = await generateChatKeyPair();
  const plaintext = 'TASK: sync build numbers before TestFlight — see .chattr-agents.json';
  const envelope = await encryptForRecipient(plaintext, encodePublicKeyBlob(pair));

  const parsed = JSON.parse(envelope);
  assert.equal(parsed.v, 3);
  assert.equal(parsed.alg, 'hybrid-kem:aes-gcm');
  assert.ok(typeof parsed.ek === 'string' && parsed.ek.length > 0);
  assert.ok(typeof parsed.msg === 'string' && parsed.msg.length > 0);

  const decrypted = await decryptEnvelope(envelope, pair);
  assert.equal(decrypted, plaintext);
});

test('encryptForAllMembers: shared ciphertext (msg) identical across recipients, wrapped key (ek) differs', async () => {
  const pairs = await Promise.all([generateChatKeyPair(), generateChatKeyPair(), generateChatKeyPair()]);
  const memberKeys: Record<string, string> = {};
  pairs.forEach((p, i) => (memberKeys[`user-${i}`] = encodePublicKeyBlob(p)));

  const envelopes = await encryptForAllMembers('group message', memberKeys);
  const parsed = Object.values(envelopes).map((e) => JSON.parse(e));

  assert.equal(new Set(parsed.map((p) => p.msg)).size, 1, 'msg must be identical across recipients');
  assert.equal(new Set(parsed.map((p) => p.ek)).size, 3, 'ek must differ per recipient');

  for (let i = 0; i < pairs.length; i++) {
    const decrypted = await decryptEnvelope(envelopes[`user-${i}`], pairs[i]);
    assert.equal(decrypted, 'group message');
  }
});

test('decryptEnvelope rejects a wrong keypair', async () => {
  const pairA = await generateChatKeyPair();
  const pairB = await generateChatKeyPair();
  const envelope = await encryptForRecipient('secret', encodePublicKeyBlob(pairA));
  await assert.rejects(() => decryptEnvelope(envelope, pairB));
});

test('decryptEnvelope rejects an unsupported envelope version', async () => {
  const pair = await generateChatKeyPair();
  const envelope = await encryptForRecipient('x', encodePublicKeyBlob(pair));
  const tampered = JSON.stringify({ ...JSON.parse(envelope), v: 2 });
  await assert.rejects(() => decryptEnvelope(tampered, pair), /Unsupported envelope version/);
});

test('handles empty strings, long messages, and emoji round-trip', async () => {
  const pair = await generateChatKeyPair();
  for (const plaintext of ['', 'A'.repeat(5000), '🔐🎉 emojis ünîçödé']) {
    const envelope = await encryptForRecipient(plaintext, encodePublicKeyBlob(pair));
    const decrypted = await decryptEnvelope(envelope, pair);
    assert.equal(decrypted, plaintext);
  }
});

// ── v4 envelope (audit H1/M3/H2) ────────────────────────────────────────────

const CTX: MessageContext = { chatId: 'chat-aaaa', senderId: 'user-sender', messageId: 'msg-0001' };

test('v4: round-trips with context + identity signature; scheme byte 0x02 leads ek', async () => {
  const pair = await generateChatKeyPair();
  const identity = await generateIdentityKeyPair();
  const plaintext = 'signed agent message';
  const sig = await signWithIdentity(identity, signingBytes(CTX, plaintext));

  const envelope = await encryptForRecipient(plaintext, v4Blob(pair), CTX, sig);
  const parsed = JSON.parse(envelope);
  assert.equal(parsed.v, 4);
  assert.equal(parsed.sig, sig);
  assert.equal(fromB64(parsed.ek)[0], KEM_SCHEME_HYBRID);

  const full = await decryptEnvelopeFull(envelope, pair, CTX);
  assert.equal(full.plaintext, plaintext);
  assert.equal(full.version, 4);
  assert.equal(full.signatureB64, sig);

  assert.equal(await verifyIdentitySignature(identity.pub, signingBytes(CTX, full.plaintext), sig), true);
  assert.equal(await verifyIdentitySignature(identity.pub, signingBytes(CTX, full.plaintext + '!'), sig), false);
});

test('v4: AAD binds chat/sender/message — wrong context fails to decrypt', async () => {
  const pair = await generateChatKeyPair();
  const envelope = await encryptForRecipient('bound', v4Blob(pair), CTX);
  for (const wrong of [
    { ...CTX, chatId: 'chat-OTHER' },
    { ...CTX, senderId: 'user-EVIL' },
    { ...CTX, messageId: 'msg-9999' },
  ]) {
    await assert.rejects(() => decryptEnvelope(envelope, pair, wrong));
  }
  assert.equal(await decryptEnvelope(envelope, pair, CTX), 'bound');
});

test('v4: downgrade protection — non-hybrid scheme byte or truncated ek rejected', async () => {
  const pair = await generateChatKeyPair();
  const envelope = await encryptForRecipient('no downgrade', v4Blob(pair), CTX);
  const parsed = JSON.parse(envelope);
  const ek = fromB64(parsed.ek);

  const wrongScheme = Buffer.from(new Uint8Array([0x01, ...ek.slice(1)])).toString('base64');
  const truncated = Buffer.from(new Uint8Array([ek[0], ...ek.slice(1, 1 + 32 + 28)])).toString('base64');
  for (const evil of [wrongScheme, truncated]) {
    await assert.rejects(() => decryptEnvelope(JSON.stringify({ ...parsed, ek: evil }), pair, CTX));
  }
  await assert.rejects(() => decryptEnvelope(envelope, pair), /needs a message context/);
});

test('KEM key binding: signPublicKeyBlob attaches "s" that verifies for the right chat only', async () => {
  const pair = await generateChatKeyPair();
  const identity = await generateIdentityKeyPair();
  const signed = await signPublicKeyBlob(identity, 'chat-ONE', encodePublicKeyBlob(pair));

  const blob = JSON.parse(signed);
  assert.ok(typeof blob.s === 'string' && blob.s.length > 0);
  // the blob minus `s` still parses for decrypt-only consumers
  assert.ok(blob.x && blob.m);

  assert.equal(await verifyIdentitySignature(identity.pub, kemBindingMessage('chat-ONE', signed), blob.s), true);
  // bound to the chat — replaying into another chat fails
  assert.equal(await verifyIdentitySignature(identity.pub, kemBindingMessage('chat-TWO', signed), blob.s), false);
});

// ── v5 envelope (forward secrecy, audit P3) ─────────────────────────────────
// v5 is v4 with the message key wrapped to a ONE-TIME prekey instead of the
// static chat key (its id rides in `pk`). The wire bytes of ek/msg/AAD are
// identical to v4 — only the key it targets + the `pk` selector change.

const V5CTX: MessageContext = {
  chatId: 'chat-interop-v5',
  senderId: 'user-node-sender',
  messageId: 'msg-interop-v5-0001',
};

const v5FixturePath = path.join(__dirname, '../../../../web_crypto/testdata/interop_v5.json');

test('v5: wraps to a one-time prekey, carries pk, round-trips with the prekey key', async () => {
  const staticPair = await generateChatKeyPair();
  const prekeyPair = await generateChatKeyPair();
  const identity = await generateIdentityKeyPair();
  const signedPrekey = await signPublicKeyBlob(identity, V5CTX.chatId, encodePublicKeyBlob(prekeyPair));
  const plaintext = 'forward-secret agent message 🔐';
  const sig = await signWithIdentity(identity, signingBytes(V5CTX, plaintext));

  const out = await encryptForAllMembers(
    plaintext,
    { bob: v4Blob(staticPair) },
    V5CTX,
    sig,
    { bob: { prekeyId: 'pk-interop-1', publicBlob: signedPrekey } },
  );
  const parsed = JSON.parse(out.bob);
  assert.equal(parsed.v, 5);
  assert.equal(parsed.pk, 'pk-interop-1');
  assert.equal(fromB64(parsed.ek)[0], KEM_SCHEME_HYBRID);

  // Decrypts with the PREKEY key (not the static key) — that is the whole point.
  const full = await decryptEnvelopeFull(out.bob, prekeyPair, V5CTX);
  assert.equal(full.plaintext, plaintext);
  assert.equal(full.version, 5);
  // The static key cannot open it (proves it truly targets the prekey).
  await assert.rejects(() => decryptEnvelopeFull(out.bob, staticPair, V5CTX));

  // Seed the committed cross-impl fixture ONCE if missing. It is a STABLE
  // known-answer vector after that (verified below + by the Dart client), so we
  // never overwrite it — regenerating with fresh random keys on every run would
  // make the committed file non-reproducible and dirty git on each test.
  if (!existsSync(v5FixturePath)) {
    writeFileSync(
      v5FixturePath,
      JSON.stringify(
        {
          xPriv: prekeyPair.xPriv,
          mPriv: prekeyPair.mPriv,
          identityPub: identity.pub,
          chatId: V5CTX.chatId,
          senderId: V5CTX.senderId,
          messageId: V5CTX.messageId,
          prekeyId: 'pk-interop-1',
          plaintext,
          envelope: out.bob,
        },
        null,
        2,
      ) + '\n',
    );
  }
});

test('v5: the committed cross-impl vector decrypts to its known plaintext', () => {
  // Stable known-answer check against the same fixture the Dart client reads —
  // proves both impls agree on the v5 wire bytes, without regenerating the file.
  const v = JSON.parse(readFileSync(v5FixturePath, 'utf8')) as Record<string, string>;
  const ctx: MessageContext = { chatId: v.chatId, senderId: v.senderId, messageId: v.messageId };
  const pair = { xPub: '', mPub: '', xPriv: v.xPriv, mPriv: v.mPriv };
  return decryptEnvelopeFull(v.envelope, pair, ctx).then((full) => {
    assert.equal(full.version, 5);
    assert.equal(full.plaintext, v.plaintext);
  });
});
