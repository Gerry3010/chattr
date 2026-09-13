-- RLS regression test: pending request withdrawal (7.4) + block enforcement (7.5).
--
-- Run against the local stack:
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -v ON_ERROR_STOP=1 -f supabase/tests/rls_pending_withdraw_block.sql
--
-- Expected output:
--   normal_withdraw_deleted=1   (a user may withdraw their own pending request)
--   blocked_withdraw_deleted=0  (a blocked user may NOT delete their request)
--   blocked_row_remains=1       (the block persists, so they can't re-request)
--
-- (Realtime-trigger WARNINGs in a plain psql session are noise, not failures.)

BEGIN;

INSERT INTO auth.users (id, instance_id, aud, role, email) VALUES
 ('11111111-1111-1111-1111-111111111111','00000000-0000-0000-0000-000000000000','authenticated','authenticated','admin@t.de'),
 ('22222222-2222-2222-2222-222222222222','00000000-0000-0000-0000-000000000000','authenticated','authenticated','normal@t.de'),
 ('33333333-3333-3333-3333-333333333333','00000000-0000-0000-0000-000000000000','authenticated','authenticated','blocked@t.de');
INSERT INTO profiles (id, username) VALUES
 ('11111111-1111-1111-1111-111111111111','admin'),
 ('22222222-2222-2222-2222-222222222222','normal'),
 ('33333333-3333-3333-3333-333333333333','blocked');
INSERT INTO chats (id, name, admins) VALUES
 ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','Test', ARRAY['11111111-1111-1111-1111-111111111111']::uuid[]);
INSERT INTO pending_chat_members (chat_id, user_id, public_key) VALUES
 ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','22222222-2222-2222-2222-222222222222','k'),
 ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','33333333-3333-3333-3333-333333333333','k');
UPDATE pending_chat_members SET blocked_at = NOW()
 WHERE user_id='33333333-3333-3333-3333-333333333333';

SET LOCAL ROLE authenticated;

SET LOCAL "request.jwt.claims" = '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}';
WITH d AS (DELETE FROM pending_chat_members WHERE user_id='22222222-2222-2222-2222-222222222222' RETURNING 1)
SELECT 'normal_withdraw_deleted=' || count(*) FROM d;

SET LOCAL "request.jwt.claims" = '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}';
WITH d AS (DELETE FROM pending_chat_members WHERE user_id='33333333-3333-3333-3333-333333333333' RETURNING 1)
SELECT 'blocked_withdraw_deleted=' || count(*) FROM d;

RESET ROLE;
SELECT 'blocked_row_remains=' || count(*) FROM pending_chat_members WHERE user_id='33333333-3333-3333-3333-333333333333';

ROLLBACK;
