// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// The version distribution in the admin panel hangs on `fleet_app_versions()`
// (00076).
//
// This function is NEWER than the dashboard that reads it, and it is entirely
// dispensable for operating a Chattr instance: whoever runs an older schema
// version — any self-hoster who does not take every migration — simply does not
// have it. `collectStats` fires all the metrics at once and throws on the FIRST
// error; so without special handling a missing rollout statistic would take the
// complete overview with it: no reports, no media counts, no moderation panel,
// just a red error line.
//
// That is exactly what this test checks, because one never sees it in
// operation: our own instances HAVE the migration, everything is always green
// here.
//
// Run: deno test --allow-env --allow-net --no-check supabase/functions/tests/
import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { collectStats } from "../admin-stats/index.ts";

const FLEET = [
  { platform: "ios", app_version: "1.25.1", devices: 2, users: 2, last_seen: "2026-08-14T00:00:00Z" },
  { platform: "ios", app_version: null, devices: 52, users: 52, last_seen: "2026-08-13T00:00:00Z" },
];

/** Ein Supabase-Doppel: liefert je RPC das, was `overrides` sagt, sonst []. */
function fakeClient(overrides: Record<string, { data?: unknown; error?: unknown }>) {
  const calls: string[] = [];
  return {
    calls,
    // deno-lint-ignore require-await
    async rpc(name: string) {
      calls.push(name);
      return overrides[name] ?? { data: [], error: null };
    },
  };
}

Deno.test("fleet_app_versions landet unverändert in der Antwort", async () => {
  const c = fakeClient({ fleet_app_versions: { data: FLEET, error: null } });
  const out = await collectStats(c, "day");

  assertEquals(out.appVersions, FLEET);
  assert(c.calls.includes("fleet_app_versions"), "RPC wurde gar nicht gerufen");
});

Deno.test("fehlt die Funktion, bleibt der Rest der Übersicht stehen", async () => {
  // What Postgres reports through PostgREST when the function does not exist.
  const c = fakeClient({
    fleet_app_versions: {
      data: null,
      error: { code: "PGRST202", message: "Could not find the function public.fleet_app_versions" },
    },
    metrics_platform_mix: { data: [{ platform: "ios", value: 54 }], error: null },
  });

  // The call must NOT throw — that is the whole point.
  const out = await collectStats(c, "day");

  assertEquals(out.appVersions, []); // Panel zeigt „no data"
  assertEquals(out.platformMix, [{ platform: "ios", value: 54 }]); // Rest lebt
  assertEquals(out.bucket, "day");
});

Deno.test("ein Fehler in einer ECHTEN Kennzahl wirft weiterhin", async () => {
  // The counter-check: the leniency above applies to the fleet query alone.
  // Were it extended to all of them, the dashboard would silently deliver empty
  // tiles instead of an error message — and empty tiles are read as "zero", not
  // as "unknown".
  const c = fakeClient({
    metrics_signups: { data: null, error: { message: "boom" } },
    fleet_app_versions: { data: FLEET, error: null },
  });

  let threw = false;
  try {
    await collectStats(c, "day");
  } catch (_e) {
    threw = true;
  }
  assert(threw, "ein kaputtes metrics_signups muss durchschlagen");
});
