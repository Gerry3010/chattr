-- SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
-- SPDX-License-Identifier: AGPL-3.0-or-later
--
-- The user list behind the sign-in — the FIRST half of 00075.
--
-- Reproduced against prod on 2026-08-16, with nothing but the anon key that
-- sits in every web app anyway:
--
-- POST /storage/v1/object/list/avatars → HTTP 200, folder names = user UUIDs
--
-- With that, anybody signed out has the directory of all accounts that ever set
-- a profile picture — and can then fetch every one of them. Exactly this lever
-- stands in 00063 as evidence that the realtime attack was not a theoretical
-- one.
--
-- ⚠️ Why ONLY the policy and not `public = false` as well: 00075 does both
-- together, and the second part breaks every client before 1.22.0 — that still
-- builds the address with `getPublicUrl`, and against a private bucket that
-- answers with 400. Such a device then shows nothing but initials circles
-- everywhere.
--
-- The fleet is demonstrably not ready for that, and the measurement cannot even
-- say so precisely: 1.22.0 (signed addresses) appeared on 13.08., 1.24.0 (the
-- device reports its version) on 14.08. The window "new enough to sign, too old
-- to report" is one day wide — so "reports no version" here practically means
-- "older than 1.22". As of 2026-08-16: 5 devices report 1.25.1, 34 report
-- nothing (10 of them active in the last 7 days).
--
-- The two halves act independently, measured on staging in both directions:
--
-- State | anon listing | getPublicUrl
-- ---------------------------------+------------------+------------- before
-- (public + policy for all) | UUIDs visible | 200 ONLY policy → authenticated |
-- [] blocked | 200 ← this one full 00075 (also public=false) | [] blocked | 400
--
-- A public bucket serves `/object/public/...` without RLS; the `list` operation
-- ALWAYS goes through RLS. That is why it separates cleanly.
--
-- `public = false` therefore stays as the second half on `feat/private-avatar-
-- buckets` and is applied once the fleet is through — together with 00063.

-- The two `ALL` policies ("Users manage their own avatar", "Chat admins manage
-- group avatar") stay untouched: they do stand on TO public, but their USING
-- clause requires `auth.uid()`, which is NULL for an anonymous call — so they
-- open nothing.

DROP POLICY IF EXISTS "Avatars are publicly readable" ON storage.objects;
DROP POLICY IF EXISTS "Avatars are readable by signed-in users" ON storage.objects;
CREATE POLICY "Avatars are readable by signed-in users"
ON storage.objects FOR SELECT
TO authenticated
USING (bucket_id = 'avatars');

DROP POLICY IF EXISTS "Group avatars are publicly readable" ON storage.objects;
DROP POLICY IF EXISTS "Group avatars are readable by signed-in users" ON storage.objects;
CREATE POLICY "Group avatars are readable by signed-in users"
ON storage.objects FOR SELECT
TO authenticated
USING (bucket_id = 'group-avatars');

-- No COMMENT ON TABLE storage.buckets here: the table belongs to
-- `supabase_storage_admin`, not to the migration user — the attempt aborts with
-- "must be owner of table buckets" and takes the whole migration with it. (The
-- same applies to 00075 on `feat/private-avatar-buckets`; the same line stands
-- there and has to go before it is applied.)
