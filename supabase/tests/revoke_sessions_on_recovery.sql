-- Test for 00091: a recovery ends every earlier session of the account, and
-- nobody but the service role may trigger that.
--
-- Callable by a client, the function would log any account out of every
-- device. Called by recover-identity, it must remove exactly the sessions of
-- that one account and leave every other account's alone.
--
-- Run: psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--   -v ON_ERROR_STOP=1 -f supabase/tests/revoke_sessions_on_recovery.sql
--
-- Expected: anon_darf=0  authenticated_darf=0  service_role_darf=1
--           entfernt=2  eigene_uebrig=0  fremde_uebrig=1

BEGIN;

SELECT 'anon_darf=' || has_function_privilege(
  'anon', 'public.revoke_all_sessions(uuid)', 'EXECUTE')::int;
SELECT 'authenticated_darf=' || has_function_privilege(
  'authenticated', 'public.revoke_all_sessions(uuid)', 'EXECUTE')::int;
SELECT 'service_role_darf=' || has_function_privilege(
  'service_role', 'public.revoke_all_sessions(uuid)', 'EXECUTE')::int;

INSERT INTO auth.users (id, aud, role, email, created_at, updated_at)
VALUES
  ('91000000-0000-0000-0000-00000000000a', 'authenticated', 'authenticated',
   'revoke-a@test.invalid', now(), now()),
  ('91000000-0000-0000-0000-00000000000b', 'authenticated', 'authenticated',
   'revoke-b@test.invalid', now(), now());

-- Two installations of A (the old one and the one being replaced), one of B.
INSERT INTO auth.sessions (id, user_id, created_at, updated_at)
VALUES
  ('91000000-0000-0000-0000-0000000000a1', '91000000-0000-0000-0000-00000000000a', now(), now()),
  ('91000000-0000-0000-0000-0000000000a2', '91000000-0000-0000-0000-00000000000a', now(), now()),
  ('91000000-0000-0000-0000-0000000000b1', '91000000-0000-0000-0000-00000000000b', now(), now());

SET LOCAL ROLE service_role;
SELECT 'entfernt=' || public.revoke_all_sessions('91000000-0000-0000-0000-00000000000a');
RESET ROLE;

SELECT 'eigene_uebrig=' || count(*) FROM auth.sessions
 WHERE user_id = '91000000-0000-0000-0000-00000000000a';
SELECT 'fremde_uebrig=' || count(*) FROM auth.sessions
 WHERE user_id = '91000000-0000-0000-0000-00000000000b';

ROLLBACK;
