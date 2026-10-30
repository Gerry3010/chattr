-- Authorization test: only chat admins may manage the chat (change the admins
-- array) or remove members. A non-admin member must not be able to.
--
-- Run: psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--        -v ON_ERROR_STOP=1 -f supabase/tests/rls_admin_gates.sql
--
-- Expected (UPDATE/DELETE denied by RLS USING-clause affect 0 rows):
--   nonadmin_chat_update=0    (member cannot change chats.admins)
--   nonadmin_remove_member=0  (member cannot remove another member)
--   admin_remove_member=1     (admin can remove a member)

BEGIN;

INSERT INTO auth.users (id, instance_id, aud, role, email) VALUES
 ('aaaaaaa1-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000000','authenticated','authenticated','a@t.de'),
 ('bbbbbbb2-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000000','authenticated','authenticated','b@t.de'),
 ('ccccccc3-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000000','authenticated','authenticated','c@t.de');
INSERT INTO profiles (id, username) VALUES
 ('aaaaaaa1-0000-0000-0000-000000000001','alice'),
 ('bbbbbbb2-0000-0000-0000-000000000002','bob'),
 ('ccccccc3-0000-0000-0000-000000000003','carol');
-- Alice is the only admin; Bob and Carol are plain members. The
-- chat_creator_admin_trigger forces admins = auth.uid() on INSERT (NULL under the
-- superuser setup role), so set it explicitly afterwards.
INSERT INTO chats (id, name, admins) VALUES
 ('ddddddd4-0000-0000-0000-000000000004','C', ARRAY['aaaaaaa1-0000-0000-0000-000000000001']::uuid[]);
UPDATE chats SET admins = ARRAY['aaaaaaa1-0000-0000-0000-000000000001']::uuid[]
 WHERE id='ddddddd4-0000-0000-0000-000000000004';
INSERT INTO chat_members (chat_id, user_id, public_key) VALUES
 ('ddddddd4-0000-0000-0000-000000000004','aaaaaaa1-0000-0000-0000-000000000001','k'),
 ('ddddddd4-0000-0000-0000-000000000004','bbbbbbb2-0000-0000-0000-000000000002','k'),
 ('ddddddd4-0000-0000-0000-000000000004','ccccccc3-0000-0000-0000-000000000003','k');

SET LOCAL ROLE authenticated;

-- Bob (non-admin) tries to make himself admin -> RLS USING fails -> 0 rows.
SET LOCAL "request.jwt.claims" = '{"sub":"bbbbbbb2-0000-0000-0000-000000000002","role":"authenticated"}';
WITH u AS (
  UPDATE chats SET admins = ARRAY['bbbbbbb2-0000-0000-0000-000000000002']::uuid[]
  WHERE id='ddddddd4-0000-0000-0000-000000000004' RETURNING 1)
SELECT 'nonadmin_chat_update=' || count(*) FROM u;

-- Bob (non-admin) tries to remove Carol -> 0 rows.
WITH d AS (
  DELETE FROM chat_members
  WHERE chat_id='ddddddd4-0000-0000-0000-000000000004'
    AND user_id='ccccccc3-0000-0000-0000-000000000003' RETURNING 1)
SELECT 'nonadmin_remove_member=' || count(*) FROM d;

-- Alice (admin) removes Carol -> 1 row.
SET LOCAL "request.jwt.claims" = '{"sub":"aaaaaaa1-0000-0000-0000-000000000001","role":"authenticated"}';
WITH d AS (
  DELETE FROM chat_members
  WHERE chat_id='ddddddd4-0000-0000-0000-000000000004'
    AND user_id='ccccccc3-0000-0000-0000-000000000003' RETURNING 1)
SELECT 'admin_remove_member=' || count(*) FROM d;

ROLLBACK;
