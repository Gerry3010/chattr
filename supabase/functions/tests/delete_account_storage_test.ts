// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// The two decisions inside delete-account that can destroy data belonging to
// someone else, pinned as pure functions.
//
// Deleting an account also deletes its pictures. That is right for the
// account's own avatar, and right for a group whose last member just left —
// but a group that OUTLIVES the account keeps its picture, and getting that
// backwards would blank out a living group for everyone still in it, with no
// way back: the bytes are gone.
//
// Run: deno test --allow-env --allow-net --no-check supabase/functions/tests/
import {
  assertEquals,
  assertNotEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { objectPaths, orphanedChatIds } from "../delete-account/index.ts";

const A = "11111111-1111-1111-1111-111111111111";
const B = "22222222-2222-2222-2222-222222222222";
const C = "33333333-3333-3333-3333-333333333333";

Deno.test("a chat that survives keeps its picture", () => {
  assertEquals(orphanedChatIds([A, B], [A, B]), []);
});

Deno.test("a chat that died with the account loses its picture", () => {
  assertEquals(orphanedChatIds([A, B], [A]), [B]);
});

Deno.test("no surviving chats → every folder is orphaned", () => {
  assertEquals(orphanedChatIds([A, B], []), [A, B]);
});

Deno.test("duplicate memberships are not deleted twice", () => {
  assertEquals(orphanedChatIds([A, A, B], [B]), [A]);
});

Deno.test("chats the user was never in are ignored", () => {
  // The survivor query is scoped to the user's own chats, but a wider result
  // must never widen the deletion.
  assertEquals(orphanedChatIds([], [A, B]), []);
});

Deno.test("objectPaths prefixes the folder", () => {
  assertEquals(
    objectPaths(A, [{ name: "avatar.jpg", id: "o1" }]),
    [`${A}/avatar.jpg`],
  );
});

Deno.test("objectPaths keeps every leftover in the folder", () => {
  // The whole reason for listing instead of reading profiles.avatar_path: an
  // upload with a new extension leaves the old object behind, and the column
  // only ever names one of them.
  assertEquals(
    objectPaths(A, [
      { name: "avatar.heic", id: "o1" },
      { name: "avatar.jpg", id: "o2" },
    ]),
    [`${A}/avatar.heic`, `${A}/avatar.jpg`],
  );
});

Deno.test("objectPaths drops folders and the placeholder", () => {
  // `list()` returns nested folders with a null id, plus the zero-byte
  // .emptyFolderPlaceholder the dashboard leaves behind. Neither is a file.
  assertEquals(
    objectPaths(A, [
      { name: "nested", id: null },
      { name: ".emptyFolderPlaceholder", id: "o0" },
      { name: "avatar.jpg", id: "o1" },
    ]),
    [`${A}/avatar.jpg`],
  );
});

Deno.test("an empty folder asks for no deletion at all", () => {
  assertEquals(objectPaths(A, []), []);
});

Deno.test("the folder decides the path, not the entry name", () => {
  // Guards against passing the wrong folder: C's listing under A's folder must
  // not silently produce a valid-looking path in the wrong place.
  assertNotEquals(
    objectPaths(A, [{ name: "avatar.jpg", id: "o1" }])[0],
    `${C}/avatar.jpg`,
  );
});
