-- Regression test for 00093 (CHAT-16): bind_mcp_chat no longer lets a plain
-- member take over a group, while the real MCP flow (agent creates a chat,
-- binds it, the owner's app joins) keeps working.
--
-- Run: psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--        -v ON_ERROR_STOP=1 -f supabase/tests/mcp_bind_requires_fresh_chat.sql
--
-- Expected (each check RAISEs on the wrong outcome, so a SQL error = failure):
--   member_bind_blocked=1     member with their own token cannot bind a group
--   admin_bind_busy_blocked=1 even the admin cannot bind a chat with members
--   takeover_admins_intact=1  the group's admins are unchanged afterwards
--   agent_bind_ok=1           agent binds its fresh chat to the owner's token
--   owner_auto_approved=1     owner's join request is promoted ...
--   owner_sole_admin=1        ... and the owner becomes the sole admin
--   second_lock_holds=1       a bound chat with other members never auto-promotes

BEGIN;

INSERT INTO auth.users (id, instance_id, aud, role, email) VALUES
 ('a1000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-000000000000','authenticated','authenticated','alice@t.de'),
 ('b2000000-0000-0000-0000-0000000000b2','00000000-0000-0000-0000-000000000000','authenticated','authenticated','bob@t.de'),
 ('e3000000-0000-0000-0000-0000000000e3','00000000-0000-0000-0000-000000000000','authenticated','authenticated','eve@t.de'),
 ('a4000000-0000-0000-0000-0000000000a4','00000000-0000-0000-0000-000000000000','authenticated','authenticated','agent@t.de'),
 ('f5000000-0000-0000-0000-0000000000f5','00000000-0000-0000-0000-000000000000','authenticated','authenticated','owner@t.de');
INSERT INTO profiles (id, username, is_agent) VALUES
 ('a1000000-0000-0000-0000-0000000000a1','alice', false),
 ('b2000000-0000-0000-0000-0000000000b2','bob', false),
 ('e3000000-0000-0000-0000-0000000000e3','eve', false),
 -- is_agent false on purpose: agent profiles from before 00068 look like this.
 ('a4000000-0000-0000-0000-0000000000a4','proj-claude', false),
 ('f5000000-0000-0000-0000-0000000000f5','owner', false);

-- An existing group: Alice is admin, Bob and Eve are members.
INSERT INTO chats (id, name, is_group) VALUES
 ('c1000000-0000-0000-0000-0000000000c1','Familie', true);
UPDATE chats SET admins = ARRAY['a1000000-0000-0000-0000-0000000000a1']::uuid[]
 WHERE id = 'c1000000-0000-0000-0000-0000000000c1';
INSERT INTO chat_members (chat_id, user_id, public_key) VALUES
 ('c1000000-0000-0000-0000-0000000000c1','a1000000-0000-0000-0000-0000000000a1','k'),
 ('c1000000-0000-0000-0000-0000000000c1','b2000000-0000-0000-0000-0000000000b2','k'),
 ('c1000000-0000-0000-0000-0000000000c1','e3000000-0000-0000-0000-0000000000e3','k');

-- MCP tokens: Eve mints her own (the attack), the owner has one for the agent.
INSERT INTO mcp_tokens (owner_id, token_hash, label) VALUES
 ('e3000000-0000-0000-0000-0000000000e3', encode(extensions.digest('eve-token', 'sha256'), 'hex'), 'eve'),
 ('f5000000-0000-0000-0000-0000000000f5', encode(extensions.digest('owner-token', 'sha256'), 'hex'), 'owner');

SET LOCAL ROLE authenticated;

-- 1. Eve (plain member) binds the family group to herself → refused.
SET LOCAL "request.jwt.claims" = '{"sub":"e3000000-0000-0000-0000-0000000000e3","role":"authenticated"}';
DO $$
BEGIN
  PERFORM public.bind_mcp_chat('c1000000-0000-0000-0000-0000000000c1', 'eve-token');
  RAISE EXCEPTION 'FAIL: member bound an existing group';
EXCEPTION WHEN insufficient_privilege THEN NULL;
END $$;
SELECT 'member_bind_blocked=' || count(*) FROM chats
 WHERE id = 'c1000000-0000-0000-0000-0000000000c1' AND NOT is_mcp;

-- 2. Even Alice (admin) cannot bind a chat that has other members.
SET LOCAL "request.jwt.claims" = '{"sub":"a1000000-0000-0000-0000-0000000000a1","role":"authenticated"}';
DO $$
BEGIN
  PERFORM public.bind_mcp_chat('c1000000-0000-0000-0000-0000000000c1', 'owner-token');
  RAISE EXCEPTION 'FAIL: admin bound a chat with members';
EXCEPTION WHEN insufficient_privilege THEN NULL;
END $$;
SELECT 'admin_bind_busy_blocked=' || count(*) FROM chats
 WHERE id = 'c1000000-0000-0000-0000-0000000000c1' AND NOT is_mcp;

-- 3. Eve files the pending row of the old attack anyway → nothing changes.
SET LOCAL "request.jwt.claims" = '{"sub":"e3000000-0000-0000-0000-0000000000e3","role":"authenticated"}';
INSERT INTO pending_chat_members (chat_id, user_id, public_key)
VALUES ('c1000000-0000-0000-0000-0000000000c1','e3000000-0000-0000-0000-0000000000e3','k')
ON CONFLICT DO NOTHING;
RESET ROLE;
SELECT 'takeover_admins_intact=' || count(*) FROM chats
 WHERE id = 'c1000000-0000-0000-0000-0000000000c1'
   AND admins = ARRAY['a1000000-0000-0000-0000-0000000000a1']::uuid[];

-- 4. The real flow: the agent creates a fresh chat (it becomes admin through
--    chat_creator_admin_trigger), joins it, binds it to the owner's token.
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" = '{"sub":"a4000000-0000-0000-0000-0000000000a4","role":"authenticated"}';
INSERT INTO chats (id, name, is_group) VALUES
 ('c2000000-0000-0000-0000-0000000000c2','agents:proj', true);
INSERT INTO chat_members (chat_id, user_id, public_key) VALUES
 ('c2000000-0000-0000-0000-0000000000c2','a4000000-0000-0000-0000-0000000000a4','k');
SELECT 'agent_bind_ok=' || (public.bind_mcp_chat('c2000000-0000-0000-0000-0000000000c2', 'owner-token')
                            = 'f5000000-0000-0000-0000-0000000000f5')::int;

-- 5. The owner's app files its join request → auto-approved, sole admin.
SET LOCAL "request.jwt.claims" = '{"sub":"f5000000-0000-0000-0000-0000000000f5","role":"authenticated"}';
INSERT INTO pending_chat_members (chat_id, user_id, public_key)
VALUES ('c2000000-0000-0000-0000-0000000000c2','f5000000-0000-0000-0000-0000000000f5','k');
RESET ROLE;
SELECT 'owner_auto_approved=' || count(*) FROM chat_members
 WHERE chat_id = 'c2000000-0000-0000-0000-0000000000c2'
   AND user_id = 'f5000000-0000-0000-0000-0000000000f5';
SELECT 'owner_sole_admin=' || count(*) FROM chats
 WHERE id = 'c2000000-0000-0000-0000-0000000000c2'
   AND admins = ARRAY['f5000000-0000-0000-0000-0000000000f5']::uuid[];

-- 6. Second lock: a group that is somehow bound (simulated as the setup
--    superuser) with a human in it never promotes the bound owner.
UPDATE chats SET is_mcp = true, mcp_owner_id = 'e3000000-0000-0000-0000-0000000000e3'
 WHERE id = 'c1000000-0000-0000-0000-0000000000c1';
DELETE FROM pending_chat_members
 WHERE chat_id = 'c1000000-0000-0000-0000-0000000000c1'
   AND user_id = 'e3000000-0000-0000-0000-0000000000e3';
DELETE FROM chat_members
 WHERE chat_id = 'c1000000-0000-0000-0000-0000000000c1'
   AND user_id = 'e3000000-0000-0000-0000-0000000000e3';
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" = '{"sub":"e3000000-0000-0000-0000-0000000000e3","role":"authenticated"}';
INSERT INTO pending_chat_members (chat_id, user_id, public_key)
VALUES ('c1000000-0000-0000-0000-0000000000c1','e3000000-0000-0000-0000-0000000000e3','k');
RESET ROLE;
SELECT 'second_lock_holds=' || count(*) FROM chats
 WHERE id = 'c1000000-0000-0000-0000-0000000000c1'
   AND admins = ARRAY['a1000000-0000-0000-0000-0000000000a1']::uuid[];

DO $$
BEGIN
  IF (SELECT admins FROM chats WHERE id = 'c1000000-0000-0000-0000-0000000000c1')
     <> ARRAY['a1000000-0000-0000-0000-0000000000a1']::uuid[] THEN
    RAISE EXCEPTION 'FAIL: group admins changed';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM chats WHERE id = 'c2000000-0000-0000-0000-0000000000c2'
                 AND admins = ARRAY['f5000000-0000-0000-0000-0000000000f5']::uuid[]) THEN
    RAISE EXCEPTION 'FAIL: legit MCP flow broken';
  END IF;
END $$;

ROLLBACK;
