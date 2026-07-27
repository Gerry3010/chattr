// Copyright (C) 2026 Gerald Hofbauer <info@geraldhofbauer.net>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version. See <https://www.gnu.org/licenses/>.

// Builds a c-shared library exposing the Chattr hybrid KEM (X25519 + ML-KEM-768)
// to Flutter via dart:ffi on native platforms. Flutter web cannot use FFI and
// instead calls the JS implementation (see lib/core/crypto/ml_kem_web.dart).
package main

/*
#include <stdlib.h>
#include <string.h>
*/
import "C"

import (
	"unsafe"
)

// toC copies a Go byte slice into freshly C-allocated memory. The caller must
// free it with pb_free.
func toC(b []byte, out **C.uchar, outLen *C.int) {
	if len(b) == 0 {
		*out = nil
		*outLen = 0
		return
	}
	p := C.malloc(C.size_t(len(b)))
	C.memcpy(p, unsafe.Pointer(&b[0]), C.size_t(len(b)))
	*out = (*C.uchar)(p)
	*outLen = C.int(len(b))
}

func goBytes(p *C.uchar, n C.int) []byte {
	if p == nil || n <= 0 {
		return nil
	}
	return C.GoBytes(unsafe.Pointer(p), n)
}

//export pb_generate_mlkem768
func pb_generate_mlkem768(outPriv **C.uchar, outPrivLen *C.int, outPub **C.uchar, outPubLen *C.int) C.int {
	priv, pub, err := GenerateMLKEM768()
	if err != nil {
		return -1
	}
	toC(priv, outPriv, outPrivLen)
	toC(pub, outPub, outPubLen)
	return 0
}

//export pb_encrypt_data_key
func pb_encrypt_data_key(
	dataKey *C.uchar, dataKeyLen C.int,
	pubX *C.uchar, pubXLen C.int,
	pubM *C.uchar, pubMLen C.int,
	out **C.uchar, outLen *C.int,
) C.int {
	enc, err := EncryptDataKey(goBytes(dataKey, dataKeyLen), goBytes(pubX, pubXLen), goBytes(pubM, pubMLen))
	if err != nil {
		return -1
	}
	toC(enc, out, outLen)
	return 0
}

//export pb_decrypt_data_key
func pb_decrypt_data_key(
	encKey *C.uchar, encKeyLen C.int,
	privX *C.uchar, privXLen C.int,
	privM *C.uchar, privMLen C.int,
	out **C.uchar, outLen *C.int,
) C.int {
	dk, err := DecryptDataKey(goBytes(encKey, encKeyLen), goBytes(privX, privXLen), goBytes(privM, privMLen))
	if err != nil {
		return -1
	}
	toC(dk, out, outLen)
	return 0
}

//export pb_free
func pb_free(p *C.uchar) {
	C.free(unsafe.Pointer(p))
}

func main() {}
