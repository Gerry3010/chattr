// Copyright (C) 2026 Gerald Hofbauer <info@geraldhofbauer.net>
// AGPLv3 — see <https://www.gnu.org/licenses/>.
//
// Node roundtrip for the bundled web crypto (web/chattr_crypto.js). Loads the
// IIFE bundle (which sets globalThis.chattrCrypto), generates an X25519 keypair
// via @noble (same as the bundle does internally) and verifies the hybrid KEM
// wrap/unwrap. Run: `npm run build && npm test`.

import { x25519 } from '@noble/curves/ed25519';
import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';

const code = readFileSync(new URL('../web/chattr_crypto.js', import.meta.url), 'utf8');
// Indirect eval runs the IIFE in global scope -> sets globalThis.chattrCrypto.
(0, eval)(code);
const c = globalThis.chattrCrypto;
assert.ok(c, 'globalThis.chattrCrypto must be defined');

const { pub: mlPub, priv: mlPriv } = await c.generateMlKem768();
assert.equal(mlPub.length, 1184, 'ML-KEM-768 public key size');
assert.equal(mlPriv.length, 2400, 'ML-KEM-768 private key size');

const xPriv = x25519.utils.randomPrivateKey();
const xPub = x25519.getPublicKey(xPriv);

const dataKey = crypto.getRandomValues(new Uint8Array(32));
const enc = await c.encryptDataKey(dataKey, xPub, mlPub);
assert.ok(enc.length >= 32 + 1088, `hybrid wire size ${enc.length}`);

const dec = await c.decryptDataKey(enc, xPriv, mlPriv);
assert.deepEqual(new Uint8Array(dec), dataKey, 'roundtrip data key mismatch');

// Tamper -> reject
const bad = new Uint8Array(enc);
bad[bad.length - 1] ^= 0xff;
let threw = false;
try {
  await c.decryptDataKey(bad, xPriv, mlPriv);
} catch {
  threw = true;
}
assert.ok(threw, 'tampered ciphertext must be rejected');

console.log('web crypto roundtrip + tamper-reject OK');
