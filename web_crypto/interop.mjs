// Copyright (C) 2026 Gerald Hofbauer <info@geraldhofbauer.net>
// AGPLv3 — see <https://www.gnu.org/licenses/>.
//
// Cross-platform interop check. Reads the Go-produced vector (interop_vector.json),
// decrypts the native blob with the web bundle (proving JS reads the native wire
// format), then encrypts the same data key with the web bundle and writes it back
// as `encWeb` so the Go test can verify the reverse direction.
//
// Run: npm run build && node interop.mjs   (after the Go emit step)

import { readFileSync, writeFileSync } from 'node:fs';
import assert from 'node:assert/strict';

const path = new URL('./testdata/interop_vector.json', import.meta.url);
const v = JSON.parse(readFileSync(path, 'utf8'));

const code = readFileSync(new URL('../web/chattr_crypto.js', import.meta.url), 'utf8');
(0, eval)(code);
const c = globalThis.chattrCrypto;

const b64d = (s) => Uint8Array.from(Buffer.from(s, 'base64'));
const b64e = (u) => Buffer.from(u).toString('base64');

const dataKey = b64d(v.dataKey);

// 1) Web decrypts the native-encrypted blob.
const dec = await c.decryptDataKey(b64d(v.encNative), b64d(v.x25519Priv), b64d(v.mlkemPriv));
assert.deepEqual(new Uint8Array(dec), dataKey, 'web could not decrypt native-encrypted vector');

// 2) Web encrypts -> hand back to Go for the reverse direction.
const encWeb = await c.encryptDataKey(dataKey, b64d(v.x25519Pub), b64d(v.mlkemPub));
v.encWeb = b64e(encWeb);
writeFileSync(path, JSON.stringify(v, null, 2));

console.log('interop: web decrypted native blob OK; wrote encWeb for native verification');
