// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Authorization-gate tests for the two privileged edge functions.
//
// Both `insert-system-message` and `setup-env` use the service-role client,
// which BYPASSES RLS, so they must reject every caller that does not present
// the service-role key (a normal anon/user JWT must not be able to inject
// "system" messages or rewrite Vault secrets). These tests pin that gate.
//
// Run: deno test --allow-env --allow-net --no-check supabase/functions/tests/
//
// The 401 paths return before any Supabase client is created, so they need no
// running backend; the "valid key passes the gate" case only asserts it is NOT
// rejected with 401 (it fails downstream without a real backend, which is fine).
import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { handler as insertSystemMessage } from "../insert-system-message/index.ts";
import { handler as setupEnv } from "../setup-env/index.ts";

const SERVICE_ROLE = "service-role-test-key";
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", SERVICE_ROLE);
Deno.env.set("SUPABASE_URL", "http://127.0.0.1:54321");

function makeRequest(
  opts: { token?: string; method?: string; body?: unknown },
): Request {
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
  };
  if (opts.token !== undefined) {
    headers["Authorization"] = `Bearer ${opts.token}`;
  }
  return new Request("http://localhost/", {
    method: opts.method ?? "POST",
    headers,
    body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
  });
}

const functions = [
  { name: "insert-system-message", handler: insertSystemMessage },
  { name: "setup-env", handler: setupEnv },
] as const;

for (const { name, handler } of functions) {
  Deno.test(`${name}: no Authorization header → 401`, async () => {
    const res = await handler(makeRequest({}));
    assertEquals(res.status, 401);
  });

  Deno.test(`${name}: a non-service-role token (anon/user JWT) → 401`, async () => {
    const res = await handler(makeRequest({ token: "anon-or-user-jwt" }));
    assertEquals(res.status, 401);
  });

  Deno.test(`${name}: an empty Bearer token → 401`, async () => {
    const res = await handler(makeRequest({ token: "" }));
    assertEquals(res.status, 401);
  });

  Deno.test(`${name}: CORS preflight (OPTIONS) → 200`, async () => {
    const res = await handler(makeRequest({ method: "OPTIONS" }));
    assertEquals(res.status, 200);
  });

  Deno.test(
    `${name}: the service-role key passes the gate (not 401)`,
    async () => {
      const res = await handler(
        makeRequest({ token: SERVICE_ROLE, body: {} }),
      );
      assertEquals(res.status !== 401, true);
    },
  );
}
