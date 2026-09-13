// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Timeline of the admin panel (`landing/admin/index.html`).
//
// The panel is a single static HTML file with no test setup of its own — which
// is why this test lives here, with the repo's only JS runner. It reads the
// file, cuts out the pure helper functions and checks them without a browser.
// If somebody renames one of them, it fails by name instead of disappearing
// silently.
//
// Why at all: the charts draw only the periods the server supplies — and it
// supplies no empty ones. Without filling, two points lay side by side in the
// picture that were in reality months apart. When filling, the mapping row →
// bar is the whole truth of the chart, and it hangs on two details one does not
// see when they are wrong: date_trunc('week') starts on MONDAY in Postgres (JS
// counts from Sunday), and everything computes in UTC, because the server
// groups in UTC.
//
// Run: deno test --allow-read --allow-env --allow-net --no-check
// supabase/functions/tests/
import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";

const HTML = await Deno.readTextFile(
  new URL("../../../landing/admin/index.html", import.meta.url),
);

/** Schneidet `function <name>(…){…}` per Klammerzählung aus der Seite. */
function fnSource(name: string): string {
  const start = HTML.indexOf("function " + name + "(");
  if (start < 0) throw new Error(`function ${name}() steht nicht mehr in index.html — umbenannt?`);
  let depth = 0;
  for (let j = HTML.indexOf("{", start); j < HTML.length; j++) {
    if (HTML[j] === "{") depth++;
    else if (HTML[j] === "}" && --depth === 0) return HTML.slice(start, j + 1);
  }
  throw new Error(`function ${name}(): Klammern gehen nicht auf`);
}

function constSource(re: RegExp): string {
  const m = re.exec(HTML);
  if (!m) throw new Error(`Konstante nicht gefunden: ${re}`);
  return m[0];
}

const NAMES = ["truncUTC", "stepUTC", "keyUTC", "labelUTC", "timeline", "onTimeline", "niceMax"];
const src = [
  constSource(/var WINDOW = \{[^}]*\};/),
  constSource(/var MON = \[[^\]]*\];/),
  ...NAMES.map(fnSource),
].join("\n");

// deno-lint-ignore no-explicit-any
const P: any = new Function(`${src}\nreturn {${NAMES.join(",")}};`)();

Deno.test("Wochen beginnen am Montag — wie date_trunc('week')", () => {
  // A full week: Mon 2026-08-10 … Sun 2026-08-16 has to fall on the same
  // Monday.
  for (let d = 10; d <= 16; d++) {
    const key = P.keyUTC(P.truncUTC("week", new Date(Date.UTC(2026, 7, d))));
    assertEquals(key, "2026-08-10", `${d}.8. wurde der falschen Woche zugeordnet`);
  }
  // And the Monday after is a NEW week, not a rounding remainder.
  assertEquals(P.keyUTC(P.truncUTC("week", new Date(Date.UTC(2026, 7, 17)))), "2026-08-17");
});

Deno.test("Monat und Tag schneiden in UTC, nicht in Ortszeit", () => {
  // 23:30 UTC still belongs to the 15th — in Vienna it would already be the
  // 16th.
  const late = new Date(Date.UTC(2026, 7, 15, 23, 30));
  assertEquals(P.keyUTC(P.truncUTC("day", late)), "2026-08-15");
  assertEquals(P.keyUTC(P.truncUTC("month", late)), "2026-08-01");
});

Deno.test("die Achse ist lückenlos und endet in der laufenden Periode", () => {
  for (const [bucket, len] of [["day", 30], ["week", 12], ["month", 12]] as const) {
    const tl = P.timeline(bucket);
    assertEquals(tl.length, len, `${bucket}: falsche Fensterlänge`);
    assertEquals(
      tl[tl.length - 1].key,
      P.keyUTC(P.truncUTC(bucket, new Date())),
      `${bucket}: letzte Periode ist nicht die laufende`,
    );
    // Every period is exactly one step after its predecessor — no gap, no
    // duplicate. That was precisely not guaranteed before.
    for (let i = 1; i < tl.length; i++) {
      const erwartet = P.keyUTC(P.stepUTC(bucket, new Date(tl[i - 1].key + "T00:00:00Z"), 1));
      assertEquals(tl[i].key, erwartet, `${bucket}: Sprung bei Index ${i}`);
    }
  }
});

Deno.test("onTimeline füllt fehlende Perioden mit 0 und trifft die richtige", () => {
  const tl = P.timeline("day");
  const heute = tl[tl.length - 1].key, vorgestern = tl[tl.length - 3].key;
  const reihe = P.onTimeline(
    [
      { bucket: heute + "T00:00:00+00:00", value: 5 },
      { bucket: vorgestern + "T00:00:00+00:00", value: 3 },
      { bucket: "2019-01-01T00:00:00+00:00", value: 99 }, // außerhalb des Fensters
    ],
    "day",
    "bucket",
  );

  assertEquals(reihe.length, 30);
  assertEquals(reihe[29].value, 5);
  assertEquals(reihe[27].value, 3);
  assertEquals(reihe[28].value, 0, "die Lücke dazwischen muss 0 sein, nicht weggelassen");
  assertEquals(reihe.reduce((a: number, p: { value: number }) => a + p.value, 0), 8, "Zeile außerhalb des Fensters ist mitgezählt worden");
});

Deno.test("mehrere Zeilen derselben Periode werden addiert, nicht überschrieben", () => {
  // metrics_chats liefert pro Periode ZWEI Zeilen (direct + group).
  const heute = P.timeline("day").slice(-1)[0].key;
  const reihe = P.onTimeline(
    [{ bucket: heute, value: 4 }, { bucket: heute, value: 6 }],
    "day",
    "bucket",
  );
  assertEquals(reihe[29].value, 10);
});

Deno.test("die y-Obergrenze ist gerade — sonst rundet die Achsenmitte", () => {
  for (const m of [1, 2, 3, 5, 7, 41, 55, 105, 143, 999]) {
    const max = P.niceMax(m);
    assert(max >= m, `niceMax(${m}) = ${max} liegt unter dem Höchstwert`);
    assertEquals(max % 2, 0, `niceMax(${m}) = ${max} ist ungerade → Mitte wäre ,5`);
    assert(max <= Math.max(2, m * 2), `niceMax(${m}) = ${max} lässt das Diagramm unnötig flach`);
  }
  // The case that made it visible: an empty chart labelled itself "1 / 1 / 0",
  // because 0.5 was rounded to 1.
  assertEquals(P.niceMax(1), 2);
});
