-- RLS test: taking a reaction back on one's OWN message (00095).
--
-- Expected output:
--   absender_sieht_eigene=1     (the sender sees reactions on what they sent)
--   absender_loescht=1          (and can delete their own one there)
--   empfaenger_loescht=1        (the recipient still can, as before)
--   fremde_reaktion_bleibt=1    (nobody deletes someone else's reaction)
--   aussenstehender_sieht=0     (a non-member sees nothing)
--   helfer_fuer_fremde=0        (the helper says no for a chat one is not in)

BEGIN;
CREATE TEMP TABLE t (k TEXT) ON COMMIT DROP;
GRANT INSERT, SELECT ON t TO authenticated;

INSERT INTO auth.users (id, instance_id, aud, role, email) VALUES
 ('a1111111-0095-4000-8000-000000000001','00000000-0000-0000-0000-000000000000','authenticated','authenticated','rxa@t.de'),
 ('b2222222-0095-4000-8000-000000000002','00000000-0000-0000-0000-000000000000','authenticated','authenticated','rxb@t.de'),
 ('c3333333-0095-4000-8000-000000000003','00000000-0000-0000-0000-000000000000','authenticated','authenticated','rxc@t.de');
INSERT INTO profiles (id, username) VALUES
 ('a1111111-0095-4000-8000-000000000001','rx_a'),
 ('b2222222-0095-4000-8000-000000000002','rx_b'),
 ('c3333333-0095-4000-8000-000000000003','rx_c');
INSERT INTO chats (id, is_group) VALUES ('ab950000-0000-4000-8000-000000000001', FALSE);
INSERT INTO chat_members (chat_id, user_id) VALUES
 ('ab950000-0000-4000-8000-000000000001','a1111111-0095-4000-8000-000000000001'),
 ('ab950000-0000-4000-8000-000000000001','b2222222-0095-4000-8000-000000000002');
-- A writes to B: as on the server, only B's row exists.
INSERT INTO messages (id, chat_id, sender_id, recipient_id, encrypted_content) VALUES
 ('ad950000-0000-4000-8000-000000000001','ab950000-0000-4000-8000-000000000001',
  'a1111111-0095-4000-8000-000000000001','b2222222-0095-4000-8000-000000000002','x');
INSERT INTO message_reactions (message_id, user_id, reaction) VALUES
 ('ad950000-0000-4000-8000-000000000001','a1111111-0095-4000-8000-000000000001','👍'),
 ('ad950000-0000-4000-8000-000000000001','b2222222-0095-4000-8000-000000000002','👍'),
 ('ad950000-0000-4000-8000-000000000001','b2222222-0095-4000-8000-000000000002','❤️');

-- A, the sender
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" = '{"sub":"a1111111-0095-4000-8000-000000000001","role":"authenticated"}';
INSERT INTO t SELECT 'absender_sieht_eigene=' || (count(*) = 3)::int FROM message_reactions
 WHERE message_id = 'ad950000-0000-4000-8000-000000000001';
WITH d AS (DELETE FROM message_reactions
  WHERE message_id = 'ad950000-0000-4000-8000-000000000001'
    AND user_id = 'a1111111-0095-4000-8000-000000000001' AND reaction = '👍' RETURNING 1)
INSERT INTO t SELECT 'absender_loescht=' || count(*) FROM d;
WITH d AS (DELETE FROM message_reactions
  WHERE message_id = 'ad950000-0000-4000-8000-000000000001'
    AND user_id = 'b2222222-0095-4000-8000-000000000002' RETURNING 1)
INSERT INTO t SELECT 'fremde_reaktion_bleibt=' || (count(*) = 0)::int FROM d;

-- B, the recipient
SET LOCAL "request.jwt.claims" = '{"sub":"b2222222-0095-4000-8000-000000000002","role":"authenticated"}';
WITH d AS (DELETE FROM message_reactions
  WHERE message_id = 'ad950000-0000-4000-8000-000000000001'
    AND user_id = 'b2222222-0095-4000-8000-000000000002' AND reaction = '❤️' RETURNING 1)
INSERT INTO t SELECT 'empfaenger_loescht=' || count(*) FROM d;

-- C, not in the chat
SET LOCAL "request.jwt.claims" = '{"sub":"c3333333-0095-4000-8000-000000000003","role":"authenticated"}';
INSERT INTO t SELECT 'aussenstehender_sieht=' || count(*) FROM message_reactions
 WHERE message_id = 'ad950000-0000-4000-8000-000000000001';
INSERT INTO t SELECT 'helfer_fuer_fremde=' ||
 public.is_member_of_message_chat('ad950000-0000-4000-8000-000000000001')::int;

RESET ROLE;
SELECT k FROM t;
ROLLBACK;
