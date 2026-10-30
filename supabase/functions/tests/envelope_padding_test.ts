// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// System messages give their content away by size.
//
// Their payload is `{action, subject_id, subject_name}` — a small, fixed set of
// actions and a username. AES-GCM ciphertext is exactly as long as its
// plaintext, so the stored row's length nearly names the event: a join, a
// leave, a rename. That is the same metadata this project keeps out of the
// server's reach everywhere else.
//
// The padding must match `lib/core/crypto/envelope_padding.dart` and
// `mcp_server/src/crypto_port.ts` exactly — three implementations of one
// convention, which is precisely the kind of thing that drifts.
//
// Run: deno test --allow-env --allow-net --no-check supabase/functions/tests/
import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { padEnvelope } from "../insert-system-message/index.ts";

const BUCKET = 256;

function envelope(plaintextLen: number): string {
  return JSON.stringify({
    v: 4,
    alg: "hybrid-kem:aes-gcm",
    ek: "A".repeat(1532),
    msg: "B".repeat(Math.ceil((28 + plaintextLen) / 3) * 4),
  });
}

Deno.test("a join and a leave are no longer told apart by size", () => {
  // The real thing: "joined the chat" vs "left the chat" differ by a handful of
  // bytes, and that was enough.
  const lengths = new Set(
    [21, 22, 30, 45].map((n) => padEnvelope(envelope(n)).length),
  );
  assertEquals(lengths.size, 1, `still distinguishable: ${[...lengths]}`);
});

Deno.test("without padding they WOULD differ (counter-check)", () => {
  const raw = new Set([21, 30, 45].map((n) => envelope(n).length));
  assertEquals(raw.size > 1, true, "the fixture must vary in length");
});

Deno.test("every length lands exactly on the grid", () => {
  for (let n = 0; n < 400; n++) {
    assertEquals(padEnvelope(envelope(n)).length % BUCKET, 0, `plaintext ${n}`);
  }
});

Deno.test("padding never shrinks and never overshoots by a whole bucket", () => {
  for (let n = 0; n < 300; n++) {
    const raw = envelope(n);
    const added = padEnvelope(raw).length - raw.length;
    assertEquals(added > 0, true);
    assertEquals(added <= 2 * BUCKET, true, `added ${added}`);
  }
});

Deno.test("the envelope stays valid JSON and keeps its version", () => {
  const raw = envelope(30);
  const parsed = JSON.parse(padEnvelope(raw));
  const orig = JSON.parse(raw);
  assertEquals(parsed.v, orig.v);
  assertEquals(parsed.ek, orig.ek);
  assertEquals(parsed.msg, orig.msg);
});

Deno.test("exactly one field is added, and it is the agreed one", () => {
  const parsed = JSON.parse(padEnvelope(envelope(30)));
  const orig = JSON.parse(envelope(30));
  const added = Object.keys(parsed).filter((k) => !(k in orig));
  assertEquals(added, ["x"]);
});

Deno.test("the filler is random, so TOAST cannot compress it away", () => {
  const a = padEnvelope(envelope(30));
  const b = padEnvelope(envelope(30));
  assertEquals(a === b, false, "filler repeats between calls");
  assertEquals(a.length, b.length);
  const filler = JSON.parse(a).x as string;
  assertEquals(new Set(filler.split("")).size > 10, true, "too few distinct chars");
});

Deno.test("non-objects are left alone", () => {
  for (const s of ["", "not json", "[1,2]", "{}"]) {
    assertEquals(padEnvelope(s), s);
  }
});

Deno.test("a bucket of zero or less does not pad", () => {
  const raw = envelope(10);
  assertEquals(padEnvelope(raw, 0), raw);
  assertEquals(padEnvelope(raw, -8), raw);
});
