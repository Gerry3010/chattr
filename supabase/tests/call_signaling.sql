-- Function test: call signaling (00085).
--
-- Against the local stack: psql
-- "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--   -v ON_ERROR_STOP=1 -f supabase/tests/call_signaling.sql
--
-- What it pins is WHO may ring WHOM; whether the broadcast lands depends on
-- the local realtime partitions and is not part of the promise.
--
-- Expected output:
--   anon_darf=0            (no anonymous caller)
--   direkt_ok=1            (1:1 + accepted request: goes through)
--   ohne_anfrage_raised=1  (1:1 without consent: refused)
--   gruppe_raised=1        (no group calls)
--   fremder_raised=1       (not a member of the chat: refused)
--   selbst_raised=1        (calling oneself is an error)
--   zu_gross_raised=1      (oversized envelope: refused)
--   gesperrt_still=1       (blocked: silent, same as an offline peer)
--
-- (Realtime WARNINGs in a bare psql session are noise.)

BEGIN;

CREATE TEMP TABLE t (k TEXT) ON COMMIT DROP;
GRANT INSERT, SELECT ON t TO authenticated;

INSERT INTO auth.users (id, instance_id, aud, role, email) VALUES
 ('a1111111-1111-1111-1111-111111111111','00000000-0000-0000-0000-000000000000','authenticated','authenticated','ca@t.de'),
 ('b2222222-2222-2222-2222-222222222222','00000000-0000-0000-0000-000000000000','authenticated','authenticated','cb@t.de'),
 ('c3333333-3333-3333-3333-333333333333','00000000-0000-0000-0000-000000000000','authenticated','authenticated','cc@t.de'),
 ('d4444444-4444-4444-4444-444444444444','00000000-0000-0000-0000-000000000000','authenticated','authenticated','cd@t.de');
INSERT INTO profiles (id, username) VALUES
 ('a1111111-1111-1111-1111-111111111111','call_a'),
 ('b2222222-2222-2222-2222-222222222222','call_b'),
 ('c3333333-3333-3333-3333-333333333333','call_c'),
 ('d4444444-4444-4444-4444-444444444444','call_d');

-- A–B: 1:1 with consent. A–C: 1:1 without. G: group of A and B. A–D: 1:1
-- with consent, blocked afterwards.
INSERT INTO chats (id, is_group) VALUES
 ('ab000000-0000-0000-0000-000000000001', FALSE),
 ('ac000000-0000-0000-0000-000000000001', FALSE),
 ('ad000000-0000-0000-0000-000000000001', FALSE),
 ('aa000000-0000-0000-0000-00000000000a', TRUE);
INSERT INTO chat_members (chat_id, user_id) VALUES
 ('ab000000-0000-0000-0000-000000000001','a1111111-1111-1111-1111-111111111111'),
 ('ab000000-0000-0000-0000-000000000001','b2222222-2222-2222-2222-222222222222'),
 ('ac000000-0000-0000-0000-000000000001','a1111111-1111-1111-1111-111111111111'),
 ('ac000000-0000-0000-0000-000000000001','c3333333-3333-3333-3333-333333333333'),
 ('ad000000-0000-0000-0000-000000000001','a1111111-1111-1111-1111-111111111111'),
 ('ad000000-0000-0000-0000-000000000001','d4444444-4444-4444-4444-444444444444'),
 ('aa000000-0000-0000-0000-00000000000a','a1111111-1111-1111-1111-111111111111'),
 ('aa000000-0000-0000-0000-00000000000a','b2222222-2222-2222-2222-222222222222');
INSERT INTO chat_requests (requester_id, target_id, decided_at, accepted, chat_id) VALUES
 ('a1111111-1111-1111-1111-111111111111','b2222222-2222-2222-2222-222222222222', now(), TRUE,'ab000000-0000-0000-0000-000000000001'),
 ('d4444444-4444-4444-4444-444444444444','a1111111-1111-1111-1111-111111111111', now(), TRUE,'ad000000-0000-0000-0000-000000000001');
INSERT INTO blocked_users (blocker_id, blocked_id) VALUES
 ('d4444444-4444-4444-4444-444444444444','a1111111-1111-1111-1111-111111111111');

SELECT 'anon_darf=' || has_function_privilege(
  'anon', 'public.send_call_signal(uuid,uuid,uuid,text,text)', 'EXECUTE')::int;

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" = '{"sub":"a1111111-1111-1111-1111-111111111111","role":"authenticated"}';

-- Each case: did it raise? Recorded in t, printed after the blocks.
DO $$
DECLARE
  me  UUID := 'a1111111-1111-1111-1111-111111111111';
  sig UUID := gen_random_uuid();
BEGIN
  BEGIN
    PERFORM send_call_signal('ab000000-0000-0000-0000-000000000001',
      'b2222222-2222-2222-2222-222222222222', sig, 'env');
    INSERT INTO t VALUES ('direkt_ok=1');
  EXCEPTION WHEN OTHERS THEN INSERT INTO t VALUES ('direkt_ok=0'); END;

  BEGIN
    PERFORM send_call_signal('ac000000-0000-0000-0000-000000000001',
      'c3333333-3333-3333-3333-333333333333', sig, 'env');
    INSERT INTO t VALUES ('ohne_anfrage_raised=0');
  EXCEPTION WHEN OTHERS THEN INSERT INTO t VALUES ('ohne_anfrage_raised=1'); END;

  BEGIN
    PERFORM send_call_signal('aa000000-0000-0000-0000-00000000000a',
      'b2222222-2222-2222-2222-222222222222', sig, 'env');
    INSERT INTO t VALUES ('gruppe_raised=0');
  EXCEPTION WHEN OTHERS THEN INSERT INTO t VALUES ('gruppe_raised=1'); END;

  -- C is not in the A–B chat.
  BEGIN
    PERFORM send_call_signal('ab000000-0000-0000-0000-000000000001',
      'c3333333-3333-3333-3333-333333333333', sig, 'env');
    INSERT INTO t VALUES ('fremder_raised=0');
  EXCEPTION WHEN OTHERS THEN INSERT INTO t VALUES ('fremder_raised=1'); END;

  BEGIN
    PERFORM send_call_signal('ab000000-0000-0000-0000-000000000001', me, sig, 'env');
    INSERT INTO t VALUES ('selbst_raised=0');
  EXCEPTION WHEN OTHERS THEN INSERT INTO t VALUES ('selbst_raised=1'); END;

  BEGIN
    PERFORM send_call_signal('ab000000-0000-0000-0000-000000000001',
      'b2222222-2222-2222-2222-222222222222', sig, repeat('x', 40000));
    INSERT INTO t VALUES ('zu_gross_raised=0');
  EXCEPTION WHEN OTHERS THEN INSERT INTO t VALUES ('zu_gross_raised=1'); END;

  BEGIN
    PERFORM send_call_signal('ad000000-0000-0000-0000-000000000001',
      'd4444444-4444-4444-4444-444444444444', sig, 'env');
    INSERT INTO t VALUES ('gesperrt_still=1');
  EXCEPTION WHEN OTHERS THEN INSERT INTO t VALUES ('gesperrt_still=0'); END;
END $$;

SELECT k FROM t ORDER BY k;

ROLLBACK;
