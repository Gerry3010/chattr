-- RLS/function test: chat requests (00082).
--
-- Against the local stack: psql
-- "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \ -v
-- ON_ERROR_STOP=1 -f supabase/tests/chat_requests.sql
--
-- Expected output: direct_select_denied=1 (the table is closed to clients)
-- incoming_after_send=1 (the person asked sees the request …)
-- incoming_has_name=1 (… with the name, WITHOUT 00046 being opened)
-- requester_sees_nothing=0 (the requester does not read the table)
-- outgoing_pending=1 (… only their own state) incoming_after_decline=0
-- (rejected -> out of the inbox) outgoing_still_pending=1 (… but the requester
-- notices NOTHING. The core of rule 2) resend_after_decline_rows=1 (no second
-- attempt: it stays at the one row) resend_raised=0 (and it runs without an
-- error, which would be the disclosure) accepted_members=2 (accepting creates
-- the 1:1 …) accepted_both_admins=1 (… with both as admin, 00052)
-- outgoing_accepted=1 (and the requester finally sees something)
-- blocked_send_rows=0 (blocked: writes nothing …) blocked_send_raised=0 (… and
-- stays silent about it) self_request_raised=1 (requesting oneself is an error)
-- hourly_cap_at=11 (the 11th attempt within an hour fails)
-- mutual_creates_chat=1 (both request each other -> that IS the chat)
-- mutual_no_leftovers=1 (… and no request is left lying in the inbox)
-- backfill_created=1 (an existing 1:1 counts as mutually permitted)
-- backfill_is_accepted=1 (… and indeed as accepted) backfill_idempotent=0 (a
-- second run creates nothing twice)
--
-- (Realtime trigger WARNINGs in a bare psql session are noise.)

BEGIN;

-- Results of the DO blocks land here: a `SELECT 'x=0'` after a block prints the
-- 0 even when the block has fired — that would check nothing.
CREATE TEMP TABLE t (k TEXT) ON COMMIT DROP;
GRANT INSERT, SELECT ON t TO authenticated;

INSERT INTO auth.users (id, instance_id, aud, role, email) VALUES
 ('11111111-1111-1111-1111-111111111111','00000000-0000-0000-0000-000000000000','authenticated','authenticated','ann@t.de'),
 ('22222222-2222-2222-2222-222222222222','00000000-0000-0000-0000-000000000000','authenticated','authenticated','ben@t.de'),
 ('33333333-3333-3333-3333-333333333333','00000000-0000-0000-0000-000000000000','authenticated','authenticated','cem@t.de'),
 ('44444444-4444-4444-4444-444444444444','00000000-0000-0000-0000-000000000000','authenticated','authenticated','dro@t.de'),
 ('55555555-5555-5555-5555-555555555555','00000000-0000-0000-0000-000000000000','authenticated','authenticated','eva@t.de');
INSERT INTO profiles (id, username) VALUES
 ('11111111-1111-1111-1111-111111111111','ann'),
 ('22222222-2222-2222-2222-222222222222','ben'),
 ('33333333-3333-3333-3333-333333333333','cem'),
 ('44444444-4444-4444-4444-444444444444','dro'),
 ('55555555-5555-5555-5555-555555555555','eva');

SET LOCAL ROLE authenticated;

-- ── Ann fragt Ben an ────────────────────────────────────────────────────────
SET LOCAL "request.jwt.claims" = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
SELECT send_chat_request('22222222-2222-2222-2222-222222222222');

-- The table itself is closed — for the requester too.
SELECT 'requester_sees_nothing=' || count(*) FROM chat_requests;
SELECT 'outgoing_pending=' || count(*) FROM my_outgoing_chat_requests()
 WHERE state = 'pending';

SET LOCAL "request.jwt.claims" = '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}';
SELECT 'direct_select_denied=' || (count(*) = 0)::int FROM chat_requests;
SELECT 'incoming_after_send=' || count(*) FROM my_incoming_chat_requests();
SELECT 'incoming_has_name=' || count(*) FROM my_incoming_chat_requests()
 WHERE username = 'ann';

-- ── Ben lehnt still ab ──────────────────────────────────────────────────────
SELECT decline_chat_request('11111111-1111-1111-1111-111111111111');
SELECT 'incoming_after_decline=' || count(*) FROM my_incoming_chat_requests();

SET LOCAL "request.jwt.claims" = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
SELECT 'outgoing_still_pending=' || count(*) FROM my_outgoing_chat_requests()
 WHERE state = 'pending';

-- Requesting again: runs through, changes nothing. An error here would be
-- exactly the disclosure rule 2 rules out.
DO $$
BEGIN
  PERFORM send_chat_request('22222222-2222-2222-2222-222222222222');
  INSERT INTO t VALUES ('resend_raised=0');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO t VALUES ('resend_raised=1');
END $$;
RESET ROLE;
SELECT k FROM t WHERE k LIKE 'resend_raised%';
SELECT 'resend_after_decline_rows=' || count(*) FROM chat_requests
 WHERE requester_id = '11111111-1111-1111-1111-111111111111'
   AND target_id = '22222222-2222-2222-2222-222222222222';
SET LOCAL ROLE authenticated;

-- ── Ann fragt Cem an, Cem nimmt an ──────────────────────────────────────────
SET LOCAL "request.jwt.claims" = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
SELECT send_chat_request('33333333-3333-3333-3333-333333333333');
SET LOCAL "request.jwt.claims" = '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}';
SELECT accept_chat_request('11111111-1111-1111-1111-111111111111') AS new_chat \gset

RESET ROLE;
SELECT 'accepted_members=' || count(*) FROM chat_members WHERE chat_id = :'new_chat';
SELECT 'accepted_both_admins=' || (
  SELECT (array_length(admins, 1) = 2
          AND '11111111-1111-1111-1111-111111111111' = ANY(admins)
          AND '33333333-3333-3333-3333-333333333333' = ANY(admins))::int
  FROM chats WHERE id = :'new_chat');
SET LOCAL ROLE authenticated;

SET LOCAL "request.jwt.claims" = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
SELECT 'outgoing_accepted=' || count(*) FROM my_outgoing_chat_requests()
 WHERE state = 'accepted' AND chat_id = :'new_chat';

-- ── Blockiert: schreibt nichts und sagt nichts ──────────────────────────────
RESET ROLE;
INSERT INTO blocked_users (blocker_id, blocked_id)
VALUES ('44444444-4444-4444-4444-444444444444','11111111-1111-1111-1111-111111111111');
SET LOCAL ROLE authenticated;

SET LOCAL "request.jwt.claims" = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
DO $$
BEGIN
  PERFORM send_chat_request('44444444-4444-4444-4444-444444444444');
  INSERT INTO t VALUES ('blocked_send_raised=0');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO t VALUES ('blocked_send_raised=1');
END $$;
RESET ROLE;
SELECT k FROM t WHERE k LIKE 'blocked_send_raised%';
SELECT 'blocked_send_rows=' || count(*) FROM chat_requests
 WHERE target_id = '44444444-4444-4444-4444-444444444444';
SET LOCAL ROLE authenticated;

-- ── Sich selbst anfragen ────────────────────────────────────────────────────
SET LOCAL "request.jwt.claims" = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
DO $$
BEGIN
  PERFORM send_chat_request('11111111-1111-1111-1111-111111111111');
  INSERT INTO t VALUES ('self_request_raised=0');
EXCEPTION WHEN check_violation THEN
  INSERT INTO t VALUES ('self_request_raised=1');
END $$;
SELECT k FROM t WHERE k LIKE 'self_request_raised%';

-- ── Both request each other ──────────────────────────────────────────────── A
-- race between two devices: Ben requests Dro before Dro's request reaches him.
-- Two consents are the chat, not two open requests.
SET LOCAL "request.jwt.claims" = '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}';
SELECT send_chat_request('44444444-4444-4444-4444-444444444444');
SET LOCAL "request.jwt.claims" = '{"sub":"44444444-4444-4444-4444-444444444444","role":"authenticated"}';
SELECT send_chat_request('22222222-2222-2222-2222-222222222222');

RESET ROLE;
SELECT 'mutual_creates_chat=' || count(*) FROM chat_requests
 WHERE accepted AND chat_id IS NOT NULL
   AND ((requester_id = '22222222-2222-2222-2222-222222222222'
         AND target_id = '44444444-4444-4444-4444-444444444444')
     OR (requester_id = '44444444-4444-4444-4444-444444444444'
         AND target_id = '22222222-2222-2222-2222-222222222222'));
SELECT 'mutual_no_leftovers=' || (count(*) = 0)::int FROM chat_requests
 WHERE accepted IS NULL
   AND ((requester_id = '22222222-2222-2222-2222-222222222222'
         AND target_id = '44444444-4444-4444-4444-444444444444')
     OR (requester_id = '44444444-4444-4444-4444-444444444444'
         AND target_id = '22222222-2222-2222-2222-222222222222'));
SET LOCAL ROLE authenticated;

-- ── Hourly cap ─────────────────────────────────────────────────────────────
-- Eva has sent nothing yet. Ten fresh targets go through, the eleventh does
-- not.
RESET ROLE;
INSERT INTO auth.users (id, instance_id, aud, role, email)
SELECT ('66666666-6666-6666-6666-' || lpad(i::text, 12, '0'))::uuid,
       '00000000-0000-0000-0000-000000000000','authenticated','authenticated',
       'q' || i || '@t.de'
FROM generate_series(1, 11) i;
INSERT INTO profiles (id, username)
SELECT ('66666666-6666-6666-6666-' || lpad(i::text, 12, '0'))::uuid, 'q' || i
FROM generate_series(1, 11) i;
SET LOCAL ROLE authenticated;

SET LOCAL "request.jwt.claims" = '{"sub":"55555555-5555-5555-5555-555555555555","role":"authenticated"}';
DO $$
DECLARE i INT;
BEGIN
  FOR i IN 1..11 LOOP
    BEGIN
      PERFORM send_chat_request(
        ('66666666-6666-6666-6666-' || lpad(i::text, 12, '0'))::uuid);
    EXCEPTION WHEN check_violation THEN
      RETURN;
    END;
  END LOOP;
END $$;
RESET ROLE;
SELECT 'hourly_cap_at=' || (count(*) + 1) FROM chat_requests
 WHERE requester_id = '55555555-5555-5555-5555-555555555555';

-- ── Grandfathering ───────────────────────────────────────────────────────── A
-- 1:1 chat as an old client created it: chat + two members, without any request
-- row.
INSERT INTO chats (id, is_group, created_by, admins)
VALUES ('cccccccc-cccc-cccc-cccc-cccccccccccc', FALSE,
        '66666666-6666-6666-6666-000000000001',
        ARRAY['66666666-6666-6666-6666-000000000001']::uuid[]);
INSERT INTO chat_members (chat_id, user_id) VALUES
 ('cccccccc-cccc-cccc-cccc-cccccccccccc','66666666-6666-6666-6666-000000000001'),
 ('cccccccc-cccc-cccc-cccc-cccccccccccc','66666666-6666-6666-6666-000000000002');

SELECT 'backfill_created=' || backfill_direct_chat_requests();
SELECT 'backfill_is_accepted=' || count(*) FROM chat_requests
 WHERE chat_id = 'cccccccc-cccc-cccc-cccc-cccccccccccc' AND accepted;
SELECT 'backfill_idempotent=' || backfill_direct_chat_requests();

ROLLBACK;
