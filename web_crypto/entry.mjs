// Copyright (C) 2026 Gerald Hofbauer <info@geraldhofbauer.net>
// AGPLv3 — see <https://www.gnu.org/licenses/>.
//
// Web entry point: exposes the hybrid KEM (X25519 + ML-KEM-768) on
// globalThis.chattrCrypto for the Flutter web app to call via dart:js_interop
// (lib/core/crypto/ml_kem_web.dart). Bundled by `npm run build` into
// web/chattr_crypto.js. Wire format matches the native FFI library.

import { encryptDataKey, decryptDataKey } from './src/crypto/hybrid-kem.js';
import { generateMLKEM768 } from './src/crypto/mlkem.js';

globalThis.chattrCrypto = {
  generateMlKem768: async () => {
    const { priv, pub } = await generateMLKEM768();
    return { priv, pub };
  },
  encryptDataKey: (dataKey, recipX25519Pub, recipMlkemPub) =>
    encryptDataKey(dataKey, recipX25519Pub, recipMlkemPub),
  decryptDataKey: (encKey, privX25519, privMlkem) =>
    decryptDataKey(encKey, privX25519, privMlkem),
};
