-- Security test for mark_message_read(): a recipient may clear ONLY their own
-- per-recipient copy of a message (read_at set, ciphertext wiped) and must not
-- affect any other recipient's row. This underpins the E2E model where the
-- server drops ciphertext once the recipient has read it.
--
-- Run: psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--        -v ON_ERROR_STOP=1 -f supabase/tests/mark_message_read.sql
--
-- Expected:
--   bob_cleared=1     (Bob's copy: encrypted_content='' and read_at set)
--   alice_intact=1    (Alice's copy: content untouched and still unread)

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
INSERT INTO messages (id, chat_id, sender_id, recipient_id, encrypted_content) VALUES
 ('ddddddd4-0000-0000-0000-000000000004','ccccccc3-0000-0000-0000-000000000003','aaaaaaa1-0000-0000-0000-000000000001','aaaaaaa1-0000-0000-0000-000000000001','for-alice'),
 ('ddddddd4-0000-0000-0000-000000000004','ccccccc3-0000-0000-0000-000000000003','aaaaaaa1-0000-0000-0000-000000000001','bbbbbbb2-0000-0000-0000-000000000002','for-bob');

-- Bob reads the message.
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" = '{"sub":"bbbbbbb2-0000-0000-0000-000000000002","role":"authenticated"}';
SELECT mark_message_read('ddddddd4-0000-0000-0000-000000000004','ccccccc3-0000-0000-0000-000000000003');

RESET ROLE;
SELECT 'bob_cleared=' || count(*) FROM messages
 WHERE id='ddddddd4-0000-0000-0000-000000000004'
   AND recipient_id='bbbbbbb2-0000-0000-0000-000000000002'
   AND encrypted_content='' AND read_at IS NOT NULL;
SELECT 'alice_intact=' || count(*) FROM messages
 WHERE id='ddddddd4-0000-0000-0000-000000000004'
   AND recipient_id='aaaaaaa1-0000-0000-0000-000000000001'
   AND encrypted_content='for-alice' AND read_at IS NULL;

ROLLBACK;
