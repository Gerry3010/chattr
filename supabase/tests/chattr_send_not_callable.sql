-- Test for 00084: no client role may call `chattr_send`.
--
-- The function writes into ANY user's private event bus; a client that can
-- call it can forge events, and a forged `chatDeleted` wipes the victim's
-- local copy of a chat. The triggers that use it legitimately run as its owner
-- and are unaffected.
--
-- Run: psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--   -v ON_ERROR_STOP=1 -f supabase/tests/chattr_send_not_callable.sql
--
-- Expected: anon_darf=0  authenticated_darf=0  owner_darf=1

BEGIN;

SELECT 'anon_darf=' || has_function_privilege(
  'anon', 'public.chattr_send(jsonb,text,text,boolean)', 'EXECUTE')::int;
SELECT 'authenticated_darf=' || has_function_privilege(
  'authenticated', 'public.chattr_send(jsonb,text,text,boolean)', 'EXECUTE')::int;

-- The owner path stays open (every trigger runs as the owner). A privilege
-- check rather than a real send: whether the local realtime partition exists
-- is an accident of the stack, not part of the promise.
SELECT 'owner_darf=' || has_function_privilege(
  'postgres', 'public.chattr_send(jsonb,text,text,boolean)', 'EXECUTE')::int;

ROLLBACK;
