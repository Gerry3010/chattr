// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Gate/validation tests for the recovery edge functions. These assert the
// checks that run BEFORE any Supabase network call, so they need no backend
// (same approach as auth_test.ts).
//
//   enroll-recovery  — requires the caller's own user JWT (verified downstream);
//                      here we pin the pre-network rejections.
//   recover-identity — deliberately anon-callable (no session yet); auth is the
//                      Ed25519 signature, so we pin the input validation.
//
// Run: deno test --allow-env --allow-net --no-check supabase/functions/tests/
import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { handler as enrollRecovery } from "../enroll-recovery/index.ts";
import { handler as recoverIdentity } from "../recover-identity/index.ts";

Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "service-role-test-key");
Deno.env.set("SUPABASE_URL", "http://127.0.0.1:54321");
Deno.env.set("SUPABASE_ANON_KEY", "anon-test-key");

function req(opts: { token?: string; method?: string; body?: unknown }): Request {
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (opts.token !== undefined) headers["Authorization"] = `Bearer ${opts.token}`;
  return new Request("http://localhost/", {
    method: opts.method ?? "POST",
    headers,
    body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
  });
}

// ── enroll-recovery: must have the caller's own JWT ─────────────────────────
Deno.test("enroll-recovery: no Authorization → 401", async () => {
  assertEquals((await enrollRecovery(req({}))).status, 401);
});
Deno.test("enroll-recovery: empty Bearer token → 401", async () => {
  assertEquals((await enrollRecovery(req({ token: "" }))).status, 401);
});
Deno.test("enroll-recovery: CORS preflight (OPTIONS) → 200", async () => {
  assertEquals((await enrollRecovery(req({ method: "OPTIONS" }))).status, 200);
});
Deno.test("enroll-recovery: wrong method (GET) → 405", async () => {
  assertEquals((await enrollRecovery(req({ method: "GET" }))).status, 405);
});

// ── recover-identity: anon-callable, input-validated ────────────────────────
Deno.test("recover-identity: CORS preflight (OPTIONS) → 200", async () => {
  assertEquals((await recoverIdentity(req({ method: "OPTIONS" }))).status, 200);
});
Deno.test("recover-identity: wrong method (GET) → 405", async () => {
  assertEquals((await recoverIdentity(req({ method: "GET" }))).status, 405);
});
Deno.test("recover-identity: invalid JSON body → 400", async () => {
  const bad = new Request("http://localhost/", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: "{not json",
  });
  assertEquals((await recoverIdentity(bad)).status, 400);
});
Deno.test("recover-identity: missing/invalid public_key → 400", async () => {
  assertEquals((await recoverIdentity(req({ body: { action: "challenge" } }))).status, 400);
  assertEquals(
    (await recoverIdentity(req({ body: { action: "challenge", public_key: "not-32-bytes" } }))).status,
    400,
  );
});
