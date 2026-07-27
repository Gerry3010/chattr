// Copyright (C) 2026 Gerald Hofbauer <info@geraldhofbauer.net>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

// Hybrid KEM (X25519 + ML-KEM-768) for Chattr's end-to-end message encryption.
// Vendored and adapted from the passbubble crypto core (same author) so the wire
// format is identical between the native FFI library and the browser/web JS
// implementation. The only app-specific change is the HKDF info string.
//
// Scheme:
//   - Key exchange:  Hybrid KEM = X25519 ECDH + ML-KEM-768 (NIST FIPS 203)
//   - Symmetric enc: AES-256-GCM
//   - KDF for hybrid: HKDF-SHA256 (info = "chattr-hybrid-kem-v1")
//
// Wire format (per recipient):
//   [ephemeral_x25519_pub(32)] [mlkem768_ct(CiphertextSize)] [nonce(12)+ciphertext]
package main

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"

	"github.com/cloudflare/circl/dh/x25519"
	mlkem "github.com/cloudflare/circl/kem/mlkem/mlkem768"
	"golang.org/x/crypto/hkdf"
)

// hybridKDFInfo is the domain separation string mixed into the hybrid HKDF.
// It MUST match the web/JS implementation byte-for-byte for cross-platform
// decryption to work.
const hybridKDFInfo = "chattr-hybrid-kem-v1"

// ─── AES-256-GCM ──────────────────────────────────────────────────────────

// Encrypt encrypts plaintext with AES-256-GCM. Returns nonce||ciphertext.
func Encrypt(key, plaintext []byte) ([]byte, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return nil, err
	}
	return gcm.Seal(nonce, nonce, plaintext, nil), nil
}

// Decrypt decrypts nonce||ciphertext produced by Encrypt.
func Decrypt(key, data []byte) ([]byte, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	ns := gcm.NonceSize()
	if len(data) < ns {
		return nil, errors.New("crypto: ciphertext too short")
	}
	return gcm.Open(nil, data[:ns], data[ns:], nil)
}

// ─── Key Generation ───────────────────────────────────────────────────────

// GenerateX25519 generates a new X25519 key pair, returning (private, public) bytes.
func GenerateX25519() (priv []byte, pub []byte, err error) {
	var privKey x25519.Key
	if _, err := rand.Read(privKey[:]); err != nil {
		return nil, nil, err
	}
	var pubKey x25519.Key
	x25519.KeyGen(&pubKey, &privKey)
	return privKey[:], pubKey[:], nil
}

// GenerateMLKEM768 generates a new ML-KEM-768 key pair, returning (private, public) bytes.
func GenerateMLKEM768() (priv []byte, pub []byte, err error) {
	pubKey, privKey, err := mlkem.GenerateKeyPair(rand.Reader)
	if err != nil {
		return nil, nil, err
	}
	privBytes, err := privKey.MarshalBinary()
	if err != nil {
		return nil, nil, err
	}
	pubBytes, err := pubKey.MarshalBinary()
	if err != nil {
		return nil, nil, err
	}
	return privBytes, pubBytes, nil
}

// ─── Hybrid KEM (X25519 + ML-KEM-768) ────────────────────────────────────

// EncryptDataKey encrypts a 32-byte data key for a recipient using hybrid KEM.
// Recipients without a valid ML-KEM public key fall back to the legacy
// X25519-only format, which every client can decrypt.
func EncryptDataKey(dataKey, recipX25519Pub, recipMLKEMPub []byte) ([]byte, error) {
	if len(recipMLKEMPub) != mlkem.Scheme().PublicKeySize() {
		return EncryptDataKeyX25519Only(dataKey, recipX25519Pub)
	}

	// X25519 ephemeral key exchange
	var ephemPriv, ephemPub x25519.Key
	if _, err := rand.Read(ephemPriv[:]); err != nil {
		return nil, fmt.Errorf("gen ephemeral x25519: %w", err)
	}
	x25519.KeyGen(&ephemPub, &ephemPriv)

	var recipPub x25519.Key
	copy(recipPub[:], recipX25519Pub)
	var sharedX25519 x25519.Key
	if ok := x25519.Shared(&sharedX25519, &ephemPriv, &recipPub); !ok {
		return nil, errors.New("crypto: x25519 shared secret is zero (invalid public key)")
	}

	// ML-KEM-768 encapsulation
	pubKey, err := mlkem.Scheme().UnmarshalBinaryPublicKey(recipMLKEMPub)
	if err != nil {
		return nil, fmt.Errorf("parse mlkem768 pub key: %w", err)
	}
	ct, sharedMLKEM, err := mlkem.Scheme().Encapsulate(pubKey)
	if err != nil {
		return nil, fmt.Errorf("mlkem768 encapsulate: %w", err)
	}

	// Combine secrets via HKDF-SHA256
	combined := hybridKDF(sharedX25519[:], sharedMLKEM)

	// Encrypt data key with combined secret
	encDataKey, err := Encrypt(combined, dataKey)
	if err != nil {
		return nil, fmt.Errorf("encrypt data key: %w", err)
	}

	// Pack: ephemeral_x25519_pub || mlkem768_ct || encrypted_data_key
	out := make([]byte, 0, 32+len(ct)+len(encDataKey))
	out = append(out, ephemPub[:]...)
	out = append(out, ct...)
	out = append(out, encDataKey...)
	return out, nil
}

// EncryptDataKeyX25519Only produces the legacy X25519-only wire format:
// ephPub(32) || AES-256-GCM(rawSharedSecret, dataKey).
func EncryptDataKeyX25519Only(dataKey, recipX25519Pub []byte) ([]byte, error) {
	var ephemPriv, ephemPub x25519.Key
	if _, err := rand.Read(ephemPriv[:]); err != nil {
		return nil, fmt.Errorf("gen ephemeral x25519: %w", err)
	}
	x25519.KeyGen(&ephemPub, &ephemPriv)

	var recipPub, shared x25519.Key
	copy(recipPub[:], recipX25519Pub)
	if ok := x25519.Shared(&shared, &ephemPriv, &recipPub); !ok {
		return nil, errors.New("crypto: x25519 shared secret is zero (invalid public key)")
	}
	enc, err := Encrypt(shared[:], dataKey)
	if err != nil {
		return nil, fmt.Errorf("encrypt data key: %w", err)
	}
	out := make([]byte, 0, 32+len(enc))
	out = append(out, ephemPub[:]...)
	out = append(out, enc...)
	return out, nil
}

// DecryptDataKey decrypts an encrypted key, auto-detecting the wire format:
//   - Hybrid (≥ 32+ctSize bytes): ephPub(32) || mlkem_ct || AES-GCM
//   - Legacy (< that):            ephPub(32) || AES-GCM (X25519-only)
func DecryptDataKey(encKey, privX25519, privMLKEM []byte) ([]byte, error) {
	ctSize := mlkem.Scheme().CiphertextSize()
	const x25519PubLen = 32
	if len(encKey) < x25519PubLen+ctSize {
		return decryptDataKeyX25519Only(encKey, privX25519)
	}

	ephemPubBytes := encKey[:x25519PubLen]
	mlkemCT := encKey[x25519PubLen : x25519PubLen+ctSize]
	encDataKey := encKey[x25519PubLen+ctSize:]

	// X25519 ECDH
	var ephemPub, privKey x25519.Key
	copy(ephemPub[:], ephemPubBytes)
	copy(privKey[:], privX25519)
	var sharedX25519 x25519.Key
	if ok := x25519.Shared(&sharedX25519, &privKey, &ephemPub); !ok {
		return nil, errors.New("crypto: x25519 shared secret is zero")
	}

	// ML-KEM-768 decapsulation
	sk, err := mlkem.Scheme().UnmarshalBinaryPrivateKey(privMLKEM)
	if err != nil {
		return nil, fmt.Errorf("parse mlkem768 priv key: %w", err)
	}
	sharedMLKEM, err := mlkem.Scheme().Decapsulate(sk, mlkemCT)
	if err != nil {
		return nil, fmt.Errorf("mlkem768 decapsulate: %w", err)
	}

	combined := hybridKDF(sharedX25519[:], sharedMLKEM)
	return Decrypt(combined, encDataKey)
}

func decryptDataKeyX25519Only(encKey, privX25519 []byte) ([]byte, error) {
	const minLen = 32 + 12 // ephPub + AES-GCM nonce minimum
	if len(encKey) < minLen {
		return nil, errors.New("crypto: encrypted key too short")
	}
	var ephemPub, privKey, shared x25519.Key
	copy(ephemPub[:], encKey[:32])
	copy(privKey[:], privX25519)
	if ok := x25519.Shared(&shared, &privKey, &ephemPub); !ok {
		return nil, errors.New("crypto: x25519 shared secret is zero")
	}
	return Decrypt(shared[:], encKey[32:])
}

func hybridKDF(classical, pq []byte) []byte {
	ikm := append(append([]byte{}, classical...), pq...)
	r := hkdf.New(sha256.New, ikm, nil, []byte(hybridKDFInfo))
	out := make([]byte, 32)
	_, _ = io.ReadFull(r, out)
	return out
}

// RandKey generates a random 32-byte AES data key.
func RandKey() ([]byte, error) {
	k := make([]byte, 32)
	if _, err := rand.Read(k); err != nil {
		return nil, err
	}
	return k, nil
}
