// Copyright (C) 2026 Gerald Hofbauer <info@geraldhofbauer.net>
// AGPLv3 — see <https://www.gnu.org/licenses/>.
//
// ML-KEM-768 using the `mlkem` package. Ciphertext size 1088 bytes — matches
// cloudflare/circl mlkem768 used by the native FFI library.

import { createMlKem768 } from 'mlkem';

export const MLKEM768_CT_SIZE = 1088;
// ML-KEM-768 encapsulation (public) key size. Used to detect accounts without a
// valid ML-KEM key (X25519-only) and fall back to the legacy format.
export const MLKEM768_EK_SIZE = 1184;

let _instance: Awaited<ReturnType<typeof createMlKem768>> | null = null;
async function getInstance() {
  if (!_instance) _instance = await createMlKem768();
  return _instance;
}

export async function mlkemEncapsulate(
  publicKey: Uint8Array,
): Promise<{ ciphertext: Uint8Array; sharedSecret: Uint8Array }> {
  const ctx = await getInstance();
  const [ct, ss] = await ctx.encap(publicKey);
  if (ct.length !== MLKEM768_CT_SIZE) {
    throw new Error(`mlkem: unexpected ciphertext size ${ct.length}, expected ${MLKEM768_CT_SIZE}`);
  }
  return { ciphertext: ct, sharedSecret: ss };
}

export async function mlkemDecapsulate(
  privateKey: Uint8Array,
  ciphertext: Uint8Array,
): Promise<Uint8Array> {
  const ctx = await getInstance();
  return ctx.decap(ciphertext, privateKey);
}

export async function generateMLKEM768(): Promise<{ priv: Uint8Array; pub: Uint8Array }> {
  const ctx = await getInstance();
  const [pub, priv] = await ctx.generateKeyPair();
  return { priv, pub };
}
