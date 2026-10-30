-- Function test: call invites for a woken device (00088).
--
-- Expected output:
--   tabelle_direkt=0         (clients cannot read call_invites)
--   einladung_liegt=1        (an invite is kept for the woken device)
--   fremder_holt_nichts=1    (only the recipient can fetch it)
--   empfaenger_holt=1        (the recipient gets the sealed envelope)
--   nur_einmal=1             (fetching deletes it)
--   abgelaufen_weg=1         (older than 2 minutes: gone)
--   abbruch_raeumt=1         (cancel removes the pending invite)
--   abbruch_nennt_anruf=1    (the cancel push names the invite it takes back)
--   gesperrt_nichts=1        (blocked: nothing stored, no push)
--   unbekannte_art_raised=1  (only invite/cancel)

BEGIN;
CREATE TEMP TABLE t (k TEXT) ON COMMIT DROP;
GRANT INSERT, SELECT ON t TO authenticated;

INSERT INTO auth.users (id, instance_id, aud, role, email) VALUES
 ('a1111111-1111-1111-1111-111111111111','00000000-0000-0000-0000-000000000000','authenticated','authenticated','pa@t.de'),
 ('b2222222-2222-2222-2222-222222222222','00000000-0000-0000-0000-000000000000','authenticated','authenticated','pb@t.de'),
 ('d4444444-4444-4444-4444-444444444444','00000000-0000-0000-0000-000000000000','authenticated','authenticated','pd@t.de');
INSERT INTO profiles (id, username) VALUES
 ('a1111111-1111-1111-1111-111111111111','push_a'),
 ('b2222222-2222-2222-2222-222222222222','push_b'),
 ('d4444444-4444-4444-4444-444444444444','push_d');
INSERT INTO chats (id, is_group) VALUES
 ('ab000000-0000-0000-0000-000000000001', FALSE),
 ('ad000000-0000-0000-0000-000000000001', FALSE);
INSERT INTO chat_members (chat_id, user_id) VALUES
 ('ab000000-0000-0000-0000-000000000001','a1111111-1111-1111-1111-111111111111'),
 ('ab000000-0000-0000-0000-000000000001','b2222222-2222-2222-2222-222222222222'),
 ('ad000000-0000-0000-0000-000000000001','a1111111-1111-1111-1111-111111111111'),
 ('ad000000-0000-0000-0000-000000000001','d4444444-4444-4444-4444-444444444444');
INSERT INTO chat_requests (requester_id, target_id, decided_at, accepted, chat_id) VALUES
 ('a1111111-1111-1111-1111-111111111111','b2222222-2222-2222-2222-222222222222', now(), TRUE,'ab000000-0000-0000-0000-000000000001'),
 ('d4444444-4444-4444-4444-444444444444','a1111111-1111-1111-1111-111111111111', now(), TRUE,'ad000000-0000-0000-0000-000000000001');
INSERT INTO blocked_users (blocker_id, blocked_id) VALUES
 ('d4444444-4444-4444-4444-444444444444','a1111111-1111-1111-1111-111111111111');

SELECT 'tabelle_direkt=' || has_table_privilege('authenticated', 'public.call_invites', 'SELECT')::int;

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" = '{"sub":"a1111111-1111-1111-1111-111111111111","role":"authenticated"}';
SELECT send_call_signal('ab000000-0000-0000-0000-000000000001',
  'b2222222-2222-2222-2222-222222222222', '11111111-0000-0000-0000-000000000001', 'SEALED', 'invite');
SELECT send_call_signal('ad000000-0000-0000-0000-000000000001',
  'd4444444-4444-4444-4444-444444444444', '11111111-0000-0000-0000-000000000002', 'SEALED', 'invite');
DO $$ BEGIN
  PERFORM send_call_signal('ab000000-0000-0000-0000-000000000001',
    'b2222222-2222-2222-2222-222222222222', gen_random_uuid(), 'x', 'wecker');
  INSERT INTO t VALUES ('unbekannte_art_raised=0');
EXCEPTION WHEN OTHERS THEN INSERT INTO t VALUES ('unbekannte_art_raised=1'); END $$;
-- The sender itself cannot fetch what it sent.
INSERT INTO t SELECT 'fremder_holt_nichts=' || (count(*) = 0)::int
  FROM fetch_call_invite('11111111-0000-0000-0000-000000000001');

RESET ROLE;
INSERT INTO t SELECT 'einladung_liegt=' || count(*) FROM call_invites
 WHERE signal_id = '11111111-0000-0000-0000-000000000001';
INSERT INTO t SELECT 'gesperrt_nichts=' || (count(*) = 0)::int FROM call_invites
 WHERE signal_id = '11111111-0000-0000-0000-000000000002';

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" = '{"sub":"b2222222-2222-2222-2222-222222222222","role":"authenticated"}';
INSERT INTO t SELECT 'empfaenger_holt=' || (envelope = 'SEALED')::int
  FROM fetch_call_invite('11111111-0000-0000-0000-000000000001');
INSERT INTO t SELECT 'nur_einmal=' || (count(*) = 0)::int
  FROM fetch_call_invite('11111111-0000-0000-0000-000000000001');

-- Expired: plant an old one directly, then try to fetch it.
RESET ROLE;
INSERT INTO call_invites (signal_id, chat_id, sender_id, recipient_id, envelope, created_at)
VALUES ('11111111-0000-0000-0000-000000000003','ab000000-0000-0000-0000-000000000001',
  'a1111111-1111-1111-1111-111111111111','b2222222-2222-2222-2222-222222222222','OLD', now() - interval '3 minutes');
SET LOCAL ROLE authenticated;
INSERT INTO t SELECT 'abgelaufen_weg=' || (count(*) = 0)::int
  FROM fetch_call_invite('11111111-0000-0000-0000-000000000003');

-- Cancel clears what the caller left behind.
SET LOCAL "request.jwt.claims" = '{"sub":"a1111111-1111-1111-1111-111111111111","role":"authenticated"}';
SELECT send_call_signal('ab000000-0000-0000-0000-000000000001',
  'b2222222-2222-2222-2222-222222222222', '11111111-0000-0000-0000-000000000004', 'SEALED', 'invite');
SELECT send_call_signal('ab000000-0000-0000-0000-000000000001',
  'b2222222-2222-2222-2222-222222222222', '11111111-0000-0000-0000-000000000005', 'END', 'cancel');
RESET ROLE;
INSERT INTO t SELECT 'abbruch_raeumt=' || (count(*) = 0)::int FROM call_invites
 WHERE signal_id = '11111111-0000-0000-0000-000000000004';
-- What pg_net was asked to send for the cancel.
INSERT INTO t SELECT 'abbruch_nennt_anruf=' || (
  convert_from(body, 'UTF8')::jsonb #>> '{data,signal_id}'
    = '11111111-0000-0000-0000-000000000004')::int
  FROM net.http_request_queue
 WHERE convert_from(body, 'UTF8')::jsonb ->> 'type' = 'call_cancel'
 ORDER BY id DESC LIMIT 1;

SELECT k FROM t ORDER BY k;
ROLLBACK;
