// Copyright (C) 2026 Gerald Hofbauer <info@geraldhofbauer.net>
// AGPLv3 — see <https://www.gnu.org/licenses/>.

package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"os"
	"testing"
)

const interopVectorPath = "../../web_crypto/testdata/interop_vector.json"

type interopVector struct {
	X25519Priv string `json:"x25519Priv"`
	X25519Pub  string `json:"x25519Pub"`
	MlkemPriv  string `json:"mlkemPriv"`
	MlkemPub   string `json:"mlkemPub"`
	DataKey    string `json:"dataKey"`
	EncNative  string `json:"encNative"`
	EncWeb     string `json:"encWeb,omitempty"`
}

func b64(b []byte) string      { return base64.StdEncoding.EncodeToString(b) }
func unb64(s string) []byte    { d, _ := base64.StdEncoding.DecodeString(s); return d }

// TestEmitInteropVector writes a vector (keys + a fixed data key + a
// natively-encrypted blob) for the web/JS side to cross-verify. Gated so it does
// not run in the normal suite. Run with CHATTR_EMIT_VECTOR=1.
func TestEmitInteropVector(t *testing.T) {
	if os.Getenv("CHATTR_EMIT_VECTOR") == "" {
		t.Skip("set CHATTR_EMIT_VECTOR=1 to emit the interop vector")
	}
	privX, pubX, _ := GenerateX25519()
	privM, pubM, _ := GenerateMLKEM768()
	dataKey := []byte("0123456789abcdef0123456789abcdef") // fixed 32 bytes
	enc, err := EncryptDataKey(dataKey, pubX, pubM)
	if err != nil {
		t.Fatal(err)
	}
	v := interopVector{
		X25519Priv: b64(privX), X25519Pub: b64(pubX),
		MlkemPriv: b64(privM), MlkemPub: b64(pubM),
		DataKey: b64(dataKey), EncNative: b64(enc),
	}
	b, _ := json.MarshalIndent(v, "", "  ")
	if err := os.WriteFile(interopVectorPath, b, 0o644); err != nil {
		t.Fatal(err)
	}
}

// TestVerifyWebVector decrypts the blob the web side produced (encWeb) using the
// native lib, proving the JS wire format is byte-compatible. Gated; run with
// CHATTR_VERIFY_VECTOR=1 after the node interop step has filled in encWeb.
func TestVerifyWebVector(t *testing.T) {
	if os.Getenv("CHATTR_VERIFY_VECTOR") == "" {
		t.Skip("set CHATTR_VERIFY_VECTOR=1 to verify the web-produced vector")
	}
	raw, err := os.ReadFile(interopVectorPath)
	if err != nil {
		t.Fatal(err)
	}
	var v interopVector
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}
	if v.EncWeb == "" {
		t.Fatal("encWeb missing — run the node interop step first")
	}
	dec, err := DecryptDataKey(unb64(v.EncWeb), unb64(v.X25519Priv), unb64(v.MlkemPriv))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(dec, unb64(v.DataKey)) {
		t.Fatal("native could not decrypt web-encrypted vector (wire format mismatch)")
	}
}

func TestHybridKEMRoundtrip(t *testing.T) {
	privX, pubX, err := GenerateX25519()
	if err != nil {
		t.Fatal(err)
	}
	privM, pubM, err := GenerateMLKEM768()
	if err != nil {
		t.Fatal(err)
	}

	dataKey, err := RandKey()
	if err != nil {
		t.Fatal(err)
	}

	enc, err := EncryptDataKey(dataKey, pubX, pubM)
	if err != nil {
		t.Fatal(err)
	}
	// Hybrid wire format must include the ML-KEM-768 ciphertext (1088 bytes).
	if len(enc) < 32+1088 {
		t.Fatalf("hybrid ciphertext too short: %d", len(enc))
	}

	dec, err := DecryptDataKey(enc, privX, privM)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(dec, dataKey) {
		t.Fatal("roundtrip mismatch")
	}
}

func TestTamperRejected(t *testing.T) {
	privX, pubX, _ := GenerateX25519()
	privM, pubM, _ := GenerateMLKEM768()
	dataKey, _ := RandKey()
	enc, _ := EncryptDataKey(dataKey, pubX, pubM)
	enc[len(enc)-1] ^= 0xff
	if _, err := DecryptDataKey(enc, privX, privM); err == nil {
		t.Fatal("expected AES-GCM tamper to be rejected")
	}
}

func TestX25519OnlyFallback(t *testing.T) {
	privX, pubX, _ := GenerateX25519()
	dataKey, _ := RandKey()
	// No ML-KEM key -> legacy X25519-only format.
	enc, err := EncryptDataKey(dataKey, pubX, nil)
	if err != nil {
		t.Fatal(err)
	}
	dec, err := DecryptDataKey(enc, privX, nil)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(dec, dataKey) {
		t.Fatal("x25519-only roundtrip mismatch")
	}
}

func TestWrongKeyFails(t *testing.T) {
	privX, pubX, _ := GenerateX25519()
	_, pubM, _ := GenerateMLKEM768()
	privM2, _, _ := GenerateMLKEM768()
	dataKey, _ := RandKey()
	enc, _ := EncryptDataKey(dataKey, pubX, pubM)
	// Decapsulate with a different ML-KEM private key -> wrong combined secret.
	if _, err := DecryptDataKey(enc, privX, privM2); err == nil {
		t.Fatal("expected decryption with wrong ML-KEM key to fail")
	}
}
