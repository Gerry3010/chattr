-- Function test: call relay credentials (00086).
--
-- Against the local stack: psql
-- "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--   -v ON_ERROR_STOP=1 -f supabase/tests/call_relay_credentials.sql
--
-- Expected output:
--   anon_darf=0              (no anonymous caller)
--   unkonfiguriert_leer=1    (no turn_uris in Vault: empty list = stage 1)
--   stun_eintraege=1         (one STUN entry, without credentials)
--   turn_hmac_stimmt=1       (credential = base64(HMAC-SHA1(secret, username)))
--   turn_ablauf_ok=1         (expiry about a day ahead)
--   turn_ohne_konto=1        (the username carries no user id)
--   ohne_anfrage_raised=1    (1:1 without consent: no relay)
--   gruppe_raised=1          (no group calls)
--   fremder_raised=1         (not a member of the chat)
--   gesperrt_bekommt=1       (block not revealed: credentials as usual)

BEGIN;

CREATE TEMP TABLE t (k TEXT) ON COMMIT DROP;
GRANT INSERT, SELECT ON t TO authenticated;

INSERT INTO auth.users (id, instance_id, aud, role, email) VALUES
 ('a1111111-1111-1111-1111-111111111111','00000000-0000-0000-0000-000000000000','authenticated','authenticated','ra@t.de'),
 ('b2222222-2222-2222-2222-222222222222','00000000-0000-0000-0000-000000000000','authenticated','authenticated','rb@t.de'),
 ('c3333333-3333-3333-3333-333333333333','00000000-0000-0000-0000-000000000000','authenticated','authenticated','rc@t.de'),
 ('d4444444-4444-4444-4444-444444444444','00000000-0000-0000-0000-000000000000','authenticated','authenticated','rd@t.de');
INSERT INTO profiles (id, username) VALUES
 ('a1111111-1111-1111-1111-111111111111','relay_a'),
 ('b2222222-2222-2222-2222-222222222222','relay_b'),
 ('c3333333-3333-3333-3333-333333333333','relay_c'),
 ('d4444444-4444-4444-4444-444444444444','relay_d');
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

-- A stray local configuration must not decide the first case.
DELETE FROM vault.secrets WHERE name IN ('turn_uris', 'turn_secret');

SELECT 'anon_darf=' || has_function_privilege(
  'anon', 'public.get_call_ice_servers(uuid,uuid)', 'EXECUTE')::int;

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" = '{"sub":"a1111111-1111-1111-1111-111111111111","role":"authenticated"}';

INSERT INTO t SELECT 'unkonfiguriert_leer=' || (get_call_ice_servers(
  'ab000000-0000-0000-0000-000000000001',
  'b2222222-2222-2222-2222-222222222222') = '[]'::jsonb)::int;

RESET ROLE;
SELECT vault.create_secret('test-secret-123', 'turn_secret');
SELECT vault.create_secret(
  'stun:turn.example:3478, turn:turn.example:3478?transport=udp,turn:turn.example:3478?transport=tcp',
  'turn_uris');
SET LOCAL ROLE authenticated;

DO $$
DECLARE
  r JSONB;
  turn JSONB;
  u TEXT;
BEGIN
  r := get_call_ice_servers('ab000000-0000-0000-0000-000000000001',
                            'b2222222-2222-2222-2222-222222222222');
  INSERT INTO t SELECT 'stun_eintraege=' || count(*)
    FROM jsonb_array_elements(r) e
   WHERE e->'urls'->>0 LIKE 'stun:%' AND NOT e ? 'credential';
  turn := (SELECT e FROM jsonb_array_elements(r) e
            WHERE e->'urls'->>0 LIKE 'turn:%');
  u := turn->>'username';
  INSERT INTO t VALUES ('turn_hmac_stimmt=' || (turn->>'credential' =
    encode(extensions.hmac(u, 'test-secret-123', 'sha1'), 'base64'))::int);
  INSERT INTO t VALUES ('turn_ablauf_ok=' ||
    (split_part(u, ':', 1)::BIGINT - extract(epoch FROM now())::BIGINT
       BETWEEN 86000 AND 86400)::int);
  INSERT INTO t VALUES ('turn_ohne_konto=' ||
    (position('a1111111' IN u) = 0 AND jsonb_array_length(turn->'urls') = 2)::int);

  BEGIN
    PERFORM get_call_ice_servers('ac000000-0000-0000-0000-000000000001',
      'c3333333-3333-3333-3333-333333333333');
    INSERT INTO t VALUES ('ohne_anfrage_raised=0');
  EXCEPTION WHEN OTHERS THEN INSERT INTO t VALUES ('ohne_anfrage_raised=1'); END;

  BEGIN
    PERFORM get_call_ice_servers('aa000000-0000-0000-0000-00000000000a',
      'b2222222-2222-2222-2222-222222222222');
    INSERT INTO t VALUES ('gruppe_raised=0');
  EXCEPTION WHEN OTHERS THEN INSERT INTO t VALUES ('gruppe_raised=1'); END;

  BEGIN
    PERFORM get_call_ice_servers('ab000000-0000-0000-0000-000000000001',
      'c3333333-3333-3333-3333-333333333333');
    INSERT INTO t VALUES ('fremder_raised=0');
  EXCEPTION WHEN OTHERS THEN INSERT INTO t VALUES ('fremder_raised=1'); END;

  INSERT INTO t VALUES ('gesperrt_bekommt=' || (jsonb_array_length(
    get_call_ice_servers('ad000000-0000-0000-0000-000000000001',
      'd4444444-4444-4444-4444-444444444444')) = 2)::int);
END $$;

SELECT k FROM t ORDER BY k;

ROLLBACK;
