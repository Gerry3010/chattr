-- Regression test for 00093 (CHAT-17): moderation and agent-binding columns
-- are not writable through the API roles, only through the SECURITY DEFINER
-- moderation functions.
--
-- Run: psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--        -v ON_ERROR_STOP=1 -f supabase/tests/moderation_columns_locked.sql
--
-- Expected (each check RAISEs on the wrong outcome, so a SQL error = failure):
--   self_unban_blocked=1        banned user cannot clear banned_at
--   flag_reset_blocked=1        nor reset false_flags / flagging_revoked_at
--   self_agent_blocked=1        nor flip is_agent afterwards
--   own_username_update=1       ordinary profile edits still work
--   admin_chat_unban_blocked=1  group admin cannot lift chats.banned_at
--   admin_bind_columns_blocked=1  nor set is_mcp / mcp_owner_id directly
--   insert_prebound_chat_blocked=1  nor create a chat that is pre-bound
--   admin_chat_rename=1         ordinary chat edits still work
--   mod_ban_still_works=1       mod_ban_user / mod_unban_user (service_role)

BEGIN;

INSERT INTO auth.users (id, instance_id, aud, role, email) VALUES
 ('a0000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-000000000000','authenticated','authenticated','a@t.de'),
 ('b0000000-0000-0000-0000-0000000000b2','00000000-0000-0000-0000-000000000000','authenticated','authenticated','b@t.de');
INSERT INTO profiles (id, username) VALUES
 ('a0000000-0000-0000-0000-0000000000a1','alice'),
 ('b0000000-0000-0000-0000-0000000000b2','bob');
-- Alice is banned and lost her flagging right; set as the setup superuser,
-- which the guard lets through (that is the moderation path's role).
UPDATE profiles SET banned_at = now(), false_flags = 3, flagging_revoked_at = now()
 WHERE id = 'a0000000-0000-0000-0000-0000000000a1';
INSERT INTO chats (id, name, is_group, admins) VALUES
 ('c0000000-0000-0000-0000-0000000000c3','G', true, ARRAY['b0000000-0000-0000-0000-0000000000b2']::uuid[]);
UPDATE chats SET admins = ARRAY['b0000000-0000-0000-0000-0000000000b2']::uuid[]
 WHERE id = 'c0000000-0000-0000-0000-0000000000c3';
INSERT INTO chat_members (chat_id, user_id, public_key) VALUES
 ('c0000000-0000-0000-0000-0000000000c3','b0000000-0000-0000-0000-0000000000b2','k');
-- Banned only now: guard_banned_membership refuses members for a banned chat.
UPDATE chats SET banned_at = now() WHERE id = 'c0000000-0000-0000-0000-0000000000c3';

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" = '{"sub":"a0000000-0000-0000-0000-0000000000a1","role":"authenticated"}';

DO $$
BEGIN
  UPDATE profiles SET banned_at = NULL WHERE id = 'a0000000-0000-0000-0000-0000000000a1';
  RAISE EXCEPTION 'FAIL: banned user cleared banned_at';
EXCEPTION WHEN insufficient_privilege THEN NULL;
END $$;
SELECT 'self_unban_blocked=' || count(*) FROM profiles
 WHERE id = 'a0000000-0000-0000-0000-0000000000a1' AND banned_at IS NOT NULL;

DO $$
BEGIN
  UPDATE profiles SET false_flags = 0, flagging_revoked_at = NULL
   WHERE id = 'a0000000-0000-0000-0000-0000000000a1';
  RAISE EXCEPTION 'FAIL: user reset own flagging state';
EXCEPTION WHEN insufficient_privilege THEN NULL;
END $$;
SELECT 'flag_reset_blocked=' || count(*) FROM profiles
 WHERE id = 'a0000000-0000-0000-0000-0000000000a1' AND false_flags = 3;

DO $$
BEGIN
  UPDATE profiles SET is_agent = true WHERE id = 'a0000000-0000-0000-0000-0000000000a1';
  RAISE EXCEPTION 'FAIL: user flipped is_agent';
EXCEPTION WHEN insufficient_privilege THEN NULL;
END $$;
SELECT 'self_agent_blocked=' || count(*) FROM profiles
 WHERE id = 'a0000000-0000-0000-0000-0000000000a1' AND NOT is_agent;

WITH u AS (
  UPDATE profiles SET username = 'alice2'
  WHERE id = 'a0000000-0000-0000-0000-0000000000a1' RETURNING 1)
SELECT 'own_username_update=' || count(*) FROM u;

-- Bob administers the banned group.
SET LOCAL "request.jwt.claims" = '{"sub":"b0000000-0000-0000-0000-0000000000b2","role":"authenticated"}';

DO $$
BEGIN
  UPDATE chats SET banned_at = NULL WHERE id = 'c0000000-0000-0000-0000-0000000000c3';
  RAISE EXCEPTION 'FAIL: admin lifted chats.banned_at';
EXCEPTION WHEN insufficient_privilege THEN NULL;
END $$;
SELECT 'admin_chat_unban_blocked=' || count(*) FROM chats
 WHERE id = 'c0000000-0000-0000-0000-0000000000c3' AND banned_at IS NOT NULL;

DO $$
BEGIN
  UPDATE chats SET is_mcp = true, mcp_owner_id = 'b0000000-0000-0000-0000-0000000000b2'
   WHERE id = 'c0000000-0000-0000-0000-0000000000c3';
  RAISE EXCEPTION 'FAIL: admin bound the chat directly';
EXCEPTION WHEN insufficient_privilege THEN NULL;
END $$;
SELECT 'admin_bind_columns_blocked=' || count(*) FROM chats
 WHERE id = 'c0000000-0000-0000-0000-0000000000c3' AND NOT is_mcp;

DO $$
BEGIN
  INSERT INTO chats (is_group, name, is_mcp, mcp_owner_id)
  VALUES (true, 'trap', true, 'a0000000-0000-0000-0000-0000000000a1');
  RAISE EXCEPTION 'FAIL: inserted a pre-bound chat';
EXCEPTION WHEN insufficient_privilege THEN NULL;
END $$;
SELECT 'insert_prebound_chat_blocked=' || (count(*) = 0)::int FROM chats WHERE name = 'trap';

WITH u AS (
  UPDATE chats SET name = 'G2'
  WHERE id = 'c0000000-0000-0000-0000-0000000000c3' RETURNING 1)
SELECT 'admin_chat_rename=' || count(*) FROM u;

-- The moderation path itself still works (service_role → SECURITY DEFINER).
RESET ROLE;
SET LOCAL ROLE service_role;
SELECT public.mod_unban_user('a0000000-0000-0000-0000-0000000000a1');
SELECT public.mod_unban_chat('c0000000-0000-0000-0000-0000000000c3');
RESET ROLE;
SELECT 'mod_ban_still_works=' || count(*) FROM profiles p, chats c
 WHERE p.id = 'a0000000-0000-0000-0000-0000000000a1' AND p.banned_at IS NULL
   AND c.id = 'c0000000-0000-0000-0000-0000000000c3' AND c.banned_at IS NULL;

ROLLBACK;
