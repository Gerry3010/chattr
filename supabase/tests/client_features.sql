-- Function test: client features (00087).
--
-- Expected output:
--   anon_darf=0              (no anonymous caller)
--   alt_kann_nicht=1         (no announcement = cannot take calls)
--   angekuendigt_kann=1      (after announce_features({calls}))
--   unsinn_raised=1          (free text is not a capability)
--   fremder_raised=1         (outside the callable pair: no answer)

BEGIN;
CREATE TEMP TABLE t (k TEXT) ON COMMIT DROP;
GRANT INSERT, SELECT ON t TO authenticated;

INSERT INTO auth.users (id, instance_id, aud, role, email) VALUES
 ('a1111111-1111-1111-1111-111111111111','00000000-0000-0000-0000-000000000000','authenticated','authenticated','fa@t.de'),
 ('b2222222-2222-2222-2222-222222222222','00000000-0000-0000-0000-000000000000','authenticated','authenticated','fb@t.de'),
 ('c3333333-3333-3333-3333-333333333333','00000000-0000-0000-0000-000000000000','authenticated','authenticated','fc@t.de');
INSERT INTO profiles (id, username) VALUES
 ('a1111111-1111-1111-1111-111111111111','feat_a'),
 ('b2222222-2222-2222-2222-222222222222','feat_b'),
 ('c3333333-3333-3333-3333-333333333333','feat_c');
INSERT INTO chats (id, is_group) VALUES
 ('ab000000-0000-0000-0000-000000000001', FALSE),
 ('ac000000-0000-0000-0000-000000000001', FALSE);
INSERT INTO chat_members (chat_id, user_id) VALUES
 ('ab000000-0000-0000-0000-000000000001','a1111111-1111-1111-1111-111111111111'),
 ('ab000000-0000-0000-0000-000000000001','b2222222-2222-2222-2222-222222222222'),
 ('ac000000-0000-0000-0000-000000000001','a1111111-1111-1111-1111-111111111111'),
 ('ac000000-0000-0000-0000-000000000001','c3333333-3333-3333-3333-333333333333');
INSERT INTO chat_requests (requester_id, target_id, decided_at, accepted, chat_id) VALUES
 ('a1111111-1111-1111-1111-111111111111','b2222222-2222-2222-2222-222222222222', now(), TRUE,'ab000000-0000-0000-0000-000000000001');

SELECT 'anon_darf=' || has_function_privilege(
  'anon', 'public.peer_can_take_calls(uuid,uuid)', 'EXECUTE')::int;

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" = '{"sub":"a1111111-1111-1111-1111-111111111111","role":"authenticated"}';
INSERT INTO t SELECT 'alt_kann_nicht=' || (NOT peer_can_take_calls(
  'ab000000-0000-0000-0000-000000000001','b2222222-2222-2222-2222-222222222222'))::int;

SET LOCAL "request.jwt.claims" = '{"sub":"b2222222-2222-2222-2222-222222222222","role":"authenticated"}';
SELECT announce_features(ARRAY['calls']);
DO $$ BEGIN
  PERFORM announce_features(ARRAY['ruf mich an!']);
  INSERT INTO t VALUES ('unsinn_raised=0');
EXCEPTION WHEN OTHERS THEN INSERT INTO t VALUES ('unsinn_raised=1'); END $$;

SET LOCAL "request.jwt.claims" = '{"sub":"a1111111-1111-1111-1111-111111111111","role":"authenticated"}';
INSERT INTO t SELECT 'angekuendigt_kann=' || peer_can_take_calls(
  'ab000000-0000-0000-0000-000000000001','b2222222-2222-2222-2222-222222222222')::int;
DO $$ BEGIN
  PERFORM peer_can_take_calls('ac000000-0000-0000-0000-000000000001',
    'c3333333-3333-3333-3333-333333333333');
  INSERT INTO t VALUES ('fremder_raised=0');
EXCEPTION WHEN OTHERS THEN INSERT INTO t VALUES ('fremder_raised=1'); END $$;

SELECT k FROM t ORDER BY k;
ROLLBACK;
