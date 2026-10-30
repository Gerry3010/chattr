-- RLS regression test for Stage 1.3: the messages SELECT policy must be
-- recipient-only. Before migration 00010 a duplicate, over-permissive policy
-- (recipient_id = auth.uid() OR sender_id = auth.uid()) let a sender read every
-- per-recipient copy of a message. This test pins the strict behaviour.
--
-- Run: psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--        -v ON_ERROR_STOP=1 -f supabase/tests/rls_messages.sql
--
-- Expected:
--   sender_A_sees_for_M=1        (A sees only its own recipient row)
--   sender_A_sees_B_rows=0       (A canNOT read B's per-recipient copy)
--   recipient_B_sees_for_M=1     (B sees only its own row)

BEGIN;

INSERT INTO auth.users (id, instance_id, aud, role, email) VALUES
 ('aaaaaaa1-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000000','authenticated','authenticated','a@t.de'),
 ('bbbbbbb2-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000000','authenticated','authenticated','b@t.de');
INSERT INTO profiles (id, username) VALUES
 ('aaaaaaa1-0000-0000-0000-000000000001','alice'),
 ('bbbbbbb2-0000-0000-0000-000000000002','bob');
INSERT INTO chats (id, name, admins) VALUES
 ('ccccccc3-0000-0000-0000-000000000003','C', ARRAY['aaaaaaa1-0000-0000-0000-000000000001']::uuid[]);
INSERT INTO chat_members (chat_id, user_id, public_key) VALUES
 ('ccccccc3-0000-0000-0000-000000000003','aaaaaaa1-0000-0000-0000-000000000001','k'),
 ('ccccccc3-0000-0000-0000-000000000003','bbbbbbb2-0000-0000-0000-000000000002','k');
-- Alice sends one logical message -> one per-recipient row each.
INSERT INTO messages (id, chat_id, sender_id, recipient_id, encrypted_content) VALUES
 ('ddddddd4-0000-0000-0000-000000000004','ccccccc3-0000-0000-0000-000000000003','aaaaaaa1-0000-0000-0000-000000000001','aaaaaaa1-0000-0000-0000-000000000001','for-alice'),
 ('ddddddd4-0000-0000-0000-000000000004','ccccccc3-0000-0000-0000-000000000003','aaaaaaa1-0000-0000-0000-000000000001','bbbbbbb2-0000-0000-0000-000000000002','for-bob');

SET LOCAL ROLE authenticated;

-- As the SENDER Alice: she must see only HER recipient row, not Bob's copy.
SET LOCAL "request.jwt.claims" = '{"sub":"aaaaaaa1-0000-0000-0000-000000000001","role":"authenticated"}';
SELECT 'sender_A_sees_for_M=' || count(*) FROM messages
 WHERE id='ddddddd4-0000-0000-0000-000000000004';
SELECT 'sender_A_sees_B_rows=' || count(*) FROM messages
 WHERE id='ddddddd4-0000-0000-0000-000000000004'
   AND recipient_id='bbbbbbb2-0000-0000-0000-000000000002';

-- As the recipient Bob: only his own row.
SET LOCAL "request.jwt.claims" = '{"sub":"bbbbbbb2-0000-0000-0000-000000000002","role":"authenticated"}';
SELECT 'recipient_B_sees_for_M=' || count(*) FROM messages
 WHERE id='ddddddd4-0000-0000-0000-000000000004';

ROLLBACK;
