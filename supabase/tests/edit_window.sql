-- Function test: edit window (00090).
-- Rule: unread → 24 h after sending; read → 10 min after the FIRST read,
-- never past 24 h after sending.
--
-- Expected output:
--   frisch_ungelesen=1          (unread, 1 h old: editable)
--   alt_ungelesen_raised=1      (unread, 25 h old: refused)
--   eben_gelesen=1              (read 5 min ago, sent 2 h ago: editable)
--   laenger_gelesen_raised=1    (first read 20 min ago: refused)
--   erster_leser_zaehlt_raised=1 (group: one read 20 min ago, one just now)
--   fremd_null=1                (not the sender: nothing changes)

BEGIN;
CREATE TEMP TABLE t (k TEXT) ON COMMIT DROP;
GRANT INSERT, SELECT ON t TO authenticated;

INSERT INTO auth.users (id, instance_id, aud, role, email) VALUES
 ('a1111111-1111-1111-1111-111111111111','00000000-0000-0000-0000-000000000000','authenticated','authenticated','ea@t.de'),
 ('b2222222-2222-2222-2222-222222222222','00000000-0000-0000-0000-000000000000','authenticated','authenticated','eb@t.de'),
 ('c3333333-3333-3333-3333-333333333333','00000000-0000-0000-0000-000000000000','authenticated','authenticated','ec@t.de');
INSERT INTO profiles (id, username) VALUES
 ('a1111111-1111-1111-1111-111111111111','edit_a'),
 ('b2222222-2222-2222-2222-222222222222','edit_b'),
 ('c3333333-3333-3333-3333-333333333333','edit_c');
INSERT INTO chats (id, is_group) VALUES ('ab000000-0000-0000-0000-000000000001', TRUE);
INSERT INTO chat_members (chat_id, user_id) VALUES
 ('ab000000-0000-0000-0000-000000000001','a1111111-1111-1111-1111-111111111111'),
 ('ab000000-0000-0000-0000-000000000001','b2222222-2222-2222-2222-222222222222'),
 ('ab000000-0000-0000-0000-000000000001','c3333333-3333-3333-3333-333333333333');

INSERT INTO messages (id, chat_id, sender_id, recipient_id, encrypted_content, created_at, read_at) VALUES
 ('e0000000-0000-0000-0000-000000000001','ab000000-0000-0000-0000-000000000001','a1111111-1111-1111-1111-111111111111','b2222222-2222-2222-2222-222222222222','x', now() - interval '1 hour', NULL),
 ('e0000000-0000-0000-0000-000000000002','ab000000-0000-0000-0000-000000000001','a1111111-1111-1111-1111-111111111111','b2222222-2222-2222-2222-222222222222','x', now() - interval '25 hours', NULL),
 ('e0000000-0000-0000-0000-000000000003','ab000000-0000-0000-0000-000000000001','a1111111-1111-1111-1111-111111111111','b2222222-2222-2222-2222-222222222222','x', now() - interval '2 hours', now() - interval '5 minutes'),
 ('e0000000-0000-0000-0000-000000000004','ab000000-0000-0000-0000-000000000001','a1111111-1111-1111-1111-111111111111','b2222222-2222-2222-2222-222222222222','x', now() - interval '2 hours', now() - interval '20 minutes'),
 ('e0000000-0000-0000-0000-000000000005','ab000000-0000-0000-0000-000000000001','a1111111-1111-1111-1111-111111111111','b2222222-2222-2222-2222-222222222222','x', now() - interval '2 hours', now() - interval '20 minutes'),
 ('e0000000-0000-0000-0000-000000000005','ab000000-0000-0000-0000-000000000001','a1111111-1111-1111-1111-111111111111','c3333333-3333-3333-3333-333333333333','x', now() - interval '2 hours', now());

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" = '{"sub":"a1111111-1111-1111-1111-111111111111","role":"authenticated"}';

DO $$
DECLARE c JSONB := '{"b2222222-2222-2222-2222-222222222222":"neu"}';
BEGIN
  INSERT INTO t SELECT 'frisch_ungelesen=' || (edit_message('e0000000-0000-0000-0000-000000000001','ab000000-0000-0000-0000-000000000001', c) = 1)::int;
  BEGIN
    PERFORM edit_message('e0000000-0000-0000-0000-000000000002','ab000000-0000-0000-0000-000000000001', c);
    INSERT INTO t VALUES ('alt_ungelesen_raised=0');
  EXCEPTION WHEN OTHERS THEN INSERT INTO t VALUES ('alt_ungelesen_raised=' || (SQLERRM = 'edit_window_closed')::int); END;
  INSERT INTO t SELECT 'eben_gelesen=' || (edit_message('e0000000-0000-0000-0000-000000000003','ab000000-0000-0000-0000-000000000001', c) = 1)::int;
  BEGIN
    PERFORM edit_message('e0000000-0000-0000-0000-000000000004','ab000000-0000-0000-0000-000000000001', c);
    INSERT INTO t VALUES ('laenger_gelesen_raised=0');
  EXCEPTION WHEN OTHERS THEN INSERT INTO t VALUES ('laenger_gelesen_raised=' || (SQLERRM = 'edit_window_closed')::int); END;
  BEGIN
    PERFORM edit_message('e0000000-0000-0000-0000-000000000005','ab000000-0000-0000-0000-000000000001', c);
    INSERT INTO t VALUES ('erster_leser_zaehlt_raised=0');
  EXCEPTION WHEN OTHERS THEN INSERT INTO t VALUES ('erster_leser_zaehlt_raised=' || (SQLERRM = 'edit_window_closed')::int); END;
END $$;

SET LOCAL "request.jwt.claims" = '{"sub":"b2222222-2222-2222-2222-222222222222","role":"authenticated"}';
INSERT INTO t SELECT 'fremd_null=' || (edit_message('e0000000-0000-0000-0000-000000000001','ab000000-0000-0000-0000-000000000001', '{"a1111111-1111-1111-1111-111111111111":"z"}') = 0)::int;

SELECT k FROM t ORDER BY k;
ROLLBACK;
