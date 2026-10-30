-- Test for 00094: profile and group pictures are visible to those who may see
-- the profile or are in the chat, not to every signed-in account; members
-- cannot post notices typed `system`; senders cannot update their rows
-- directly; new usernames carry no invisible characters.
--
-- Run: psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--   -v ON_ERROR_STOP=1 -f supabase/tests/avatar_visibility_and_hardening.sql
--
-- Every check RAISEs on the wrong outcome, so a SQL error = failure. Before
-- 00094 the first check fails: the stranger sees all three pictures.

BEGIN;

-- alice and bob share a chat; dave asked alice for a 1:1; carl is nobody.
INSERT INTO auth.users (id, instance_id, aud, role, email) VALUES
 ('a0000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-000000000000','authenticated','authenticated','a@t.de'),
 ('b0000000-0000-0000-0000-0000000000b2','00000000-0000-0000-0000-000000000000','authenticated','authenticated','b@t.de'),
 ('c0000000-0000-0000-0000-0000000000c3','00000000-0000-0000-0000-000000000000','authenticated','authenticated','c@t.de'),
 ('d0000000-0000-0000-0000-0000000000d4','00000000-0000-0000-0000-000000000000','authenticated','authenticated','d@t.de');
INSERT INTO profiles (id, username) VALUES
 ('a0000000-0000-0000-0000-0000000000a1','alice'),
 ('b0000000-0000-0000-0000-0000000000b2','bob'),
 ('c0000000-0000-0000-0000-0000000000c3','carl'),
 ('d0000000-0000-0000-0000-0000000000d4','dave');
INSERT INTO chats (id, name, is_group, admins) VALUES
 ('e0000000-0000-0000-0000-0000000000e5','G', true, ARRAY['a0000000-0000-0000-0000-0000000000a1']::uuid[]);
INSERT INTO chat_members (chat_id, user_id, public_key) VALUES
 ('e0000000-0000-0000-0000-0000000000e5','a0000000-0000-0000-0000-0000000000a1','k'),
 ('e0000000-0000-0000-0000-0000000000e5','b0000000-0000-0000-0000-0000000000b2','k');
INSERT INTO chat_requests (requester_id, target_id) VALUES
 ('d0000000-0000-0000-0000-0000000000d4','a0000000-0000-0000-0000-0000000000a1');
INSERT INTO storage.objects (bucket_id, name, owner) VALUES
 ('avatars', 'b0000000-0000-0000-0000-0000000000b2/x.png', 'b0000000-0000-0000-0000-0000000000b2'),
 ('avatars', 'd0000000-0000-0000-0000-0000000000d4/y.png', 'd0000000-0000-0000-0000-0000000000d4'),
 ('avatars', 'c0000000-0000-0000-0000-0000000000c3/z.png', 'c0000000-0000-0000-0000-0000000000c3'),
 ('group-avatars', 'e0000000-0000-0000-0000-0000000000e5/g.png', 'a0000000-0000-0000-0000-0000000000a1');
INSERT INTO messages (id, chat_id, sender_id, recipient_id, encrypted_content, message_type) VALUES
 ('f0000000-0000-0000-0000-0000000000f6','e0000000-0000-0000-0000-0000000000e5',
  'a0000000-0000-0000-0000-0000000000a1','b0000000-0000-0000-0000-0000000000b2','x','user');

-- carl: signed in, but shares nothing with anyone.
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" = '{"sub":"c0000000-0000-0000-0000-0000000000c3","role":"authenticated"}';
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM storage.objects
   WHERE bucket_id = 'avatars' AND name NOT LIKE 'c0000000%';
  IF n <> 0 THEN RAISE EXCEPTION 'FAIL: stranger sees % foreign avatars', n; END IF;
  SELECT count(*) INTO n FROM storage.objects WHERE bucket_id = 'group-avatars';
  IF n <> 0 THEN RAISE EXCEPTION 'FAIL: stranger sees group avatar'; END IF;
END $$;

-- alice: bob (co-member) and dave (asked her) yes, carl no; the group yes.
RESET ROLE;
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" = '{"sub":"a0000000-0000-0000-0000-0000000000a1","role":"authenticated"}';
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM storage.objects
   WHERE bucket_id = 'avatars' AND name LIKE 'b0000000%';
  IF n <> 1 THEN RAISE EXCEPTION 'FAIL: alice cannot see her co-member'; END IF;
  SELECT count(*) INTO n FROM storage.objects
   WHERE bucket_id = 'avatars' AND name LIKE 'd0000000%';
  IF n <> 1 THEN RAISE EXCEPTION 'FAIL: alice cannot see who asked her'; END IF;
  SELECT count(*) INTO n FROM storage.objects
   WHERE bucket_id = 'avatars' AND name LIKE 'c0000000%';
  IF n <> 0 THEN RAISE EXCEPTION 'FAIL: alice sees a stranger'; END IF;
  SELECT count(*) INTO n FROM storage.objects WHERE bucket_id = 'group-avatars';
  IF n <> 1 THEN RAISE EXCEPTION 'FAIL: member cannot see group avatar'; END IF;
END $$;

-- alice cannot post a notice typed `system`, and cannot rewrite her row.
DO $$
BEGIN
  INSERT INTO messages (id, chat_id, sender_id, recipient_id, encrypted_content, message_type)
  VALUES ('f0000000-0000-0000-0000-0000000000f7','e0000000-0000-0000-0000-0000000000e5',
          'a0000000-0000-0000-0000-0000000000a1','b0000000-0000-0000-0000-0000000000b2','x','system');
  RAISE EXCEPTION 'FAIL: member inserted a system notice';
EXCEPTION WHEN insufficient_privilege THEN NULL;
END $$;
DO $$
DECLARE n int;
BEGIN
  UPDATE messages SET encrypted_content = 'rewritten'
   WHERE id = 'f0000000-0000-0000-0000-0000000000f6';
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 0 THEN RAISE EXCEPTION 'FAIL: sender updated the row directly'; END IF;
END $$;
-- An ordinary message still goes in.
INSERT INTO messages (id, chat_id, sender_id, recipient_id, encrypted_content)
VALUES ('f0000000-0000-0000-0000-0000000000f8','e0000000-0000-0000-0000-0000000000e5',
        'a0000000-0000-0000-0000-0000000000a1','b0000000-0000-0000-0000-0000000000b2','x');

RESET ROLE;

DO $$
BEGIN
  INSERT INTO auth.users (id, instance_id, aud, role, email) VALUES
   ('e1000000-0000-0000-0000-0000000000e1','00000000-0000-0000-0000-000000000000','authenticated','authenticated','e@t.de');
  INSERT INTO profiles (id, username) VALUES ('e1000000-0000-0000-0000-0000000000e1', 'b' || chr(8203) || 'ob');
  RAISE EXCEPTION 'FAIL: zero-width character accepted in a username';
EXCEPTION WHEN check_violation THEN NULL;
END $$;

SELECT 'avatar_visibility_and_hardening=ok';
ROLLBACK;
