-- Test for 00078 + 00079: the avatar store is closed — neither listing nor a
-- direct fetch works without signing in.
--
-- The safeguard consists of TWO parts, and both are needed: 00078 policy `TO
-- authenticated` → listing is dead. 00079 `public = false` → the direct fetch
-- is dead. The second part is not an afterthought: a `public = true` serves
-- `/object/public/...` **past RLS**, and the policy is never asked on that
-- route. Measured against prod (2026-08-20): listing already returned `[]`,
-- while the same anonymous call got a 472 KB image.
--
-- Why the second part waited so long: a device before 1.22.0 builds its image
-- address with `getPublicUrl` and, against a private bucket, shows nothing but
-- initials circles — silently, because a missing profile picture looks like
-- "they just don't have one". Release only after the fleet was through
-- (2026-08-20).
--
-- What is checked is the policy level (storage.objects), not HTTP: that is the
-- layer 00078 touches, and it is testable without a running storage API.
--
-- Run: psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \ -v
-- ON_ERROR_STOP=1 -f supabase/tests/avatar_list_requires_login.sql
--
-- Expected: anon_sieht_avatare=0 (no directory of accounts for the signed-out)
-- anon_sieht_gruppenbilder=0 (the same for chat ids) angemeldet_sieht_avatare=1
-- (the app needs the access for signed addresses) bucket_ist_privat=2 (BOTH
-- buckets private → no fetch past RLS)

BEGIN;

INSERT INTO auth.users (id, instance_id, aud, role) VALUES
 ('99999999-0000-0000-0000-000000000099','00000000-0000-0000-0000-000000000000','authenticated','authenticated');
INSERT INTO profiles (id, username) VALUES
 ('99999999-0000-0000-0000-000000000099','avatar_tester');

INSERT INTO storage.objects (bucket_id, name, owner)
VALUES ('avatars',       '99999999-0000-0000-0000-000000000099/avatar.png', '99999999-0000-0000-0000-000000000099'),
       ('group-avatars', 'aaaaaaaa-0000-0000-0000-00000000000a/avatar.png', '99999999-0000-0000-0000-000000000099');

-- Signed out: this is the call that used to return the user UUIDs.
SET LOCAL ROLE anon;
SELECT 'anon_sieht_avatare=' || count(*) FROM storage.objects WHERE bucket_id = 'avatars';
SELECT 'anon_sieht_gruppenbilder=' || count(*) FROM storage.objects WHERE bucket_id = 'group-avatars';

-- Signed in: has to keep working, otherwise the app cannot issue a signed
-- address and ALL images disappear — the fault 00078 avoids.
RESET ROLE;
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" = '{"sub":"99999999-0000-0000-0000-000000000099","role":"authenticated"}';
SELECT 'angemeldet_sieht_avatare=' || count(*) FROM storage.objects WHERE bucket_id = 'avatars';

-- And the buckets are private. If this number drops below 2, somebody has
-- reopened a bucket — for which there is a ready-made route: 00015 (line 23)
-- and 00055 (line 93) end in `ON CONFLICT DO UPDATE SET public = true`. Whoever
-- runs them again tears the safeguard open without touching a policy; this test
-- is the only place that notices.
RESET ROLE;
SELECT 'bucket_ist_privat=' || count(*) FROM storage.buckets
 WHERE id IN ('avatars','group-avatars') AND public IS FALSE;

ROLLBACK;
