-- Test for purge_dormant_accounts() (00077): deletes only accounts WITHOUT any
-- trace of use — and leaves everything else alone.
--
-- This function deletes user accounts irreversibly and runs unattended at
-- night. A criterion reaching too far is noticed by nobody until somebody
-- misses their account. So this test checks above all what has to REMAIN: every
-- trace protects, and each one is checked separately.
--
-- Run: psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \ -v
-- ON_ERROR_STOP=1 -f supabase/tests/purge_dormant_accounts.sql
--
-- Expected: trockenlauf_zaehlt=1 (dry_run finds exactly the one ghost)
-- trockenlauf_schont=1 (… and did NOT delete it in the process) geloescht=1
-- (the real run takes only it) geist_weg=0 (profile gone) geist_authuser_weg=0
-- (auth.users likewise — otherwise a dead record stays) geist_token_weg=0
-- (device_tokens hangs on auth.users, not on profiles) jung_bleibt=1 (too new,
-- however traceless) im_chat_bleibt=1 (membership protects) absender_bleibt=1
-- (a sent message protects) empfaenger_bleibt=1 (a RECEIVED message protects —
-- the CASCADE trap) frisches_geraet_bleibt=1 (a token younger than the limit
-- protects) reissleine_anzahl=1 (exceeding p_max_delete aborts)
-- reissleine_anteil=1 (exceeding p_max_percent aborts)

BEGIN;

-- All accounts are old and never "active" (last_active_date stays NULL) — they
-- differ ONLY in their respective trace, so the test really isolates one
-- criterion and does not accidentally check two at once.
INSERT INTO auth.users (id, instance_id, aud, role) VALUES
 ('11111111-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000000','authenticated','authenticated'),
 ('22222222-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000000','authenticated','authenticated'),
 ('33333333-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000000','authenticated','authenticated'),
 ('44444444-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000000','authenticated','authenticated'),
 ('55555555-0000-0000-0000-000000000005','00000000-0000-0000-0000-000000000000','authenticated','authenticated'),
 ('66666666-0000-0000-0000-000000000006','00000000-0000-0000-0000-000000000000','authenticated','authenticated'),
 ('77777777-0000-0000-0000-000000000007','00000000-0000-0000-0000-000000000000','authenticated','authenticated');

INSERT INTO profiles (id, username, created_at) VALUES
 ('11111111-0000-0000-0000-000000000001','geist',        now() - interval '9 months'),
 ('22222222-0000-0000-0000-000000000002','jung',         now() - interval '3 days'),
 ('33333333-0000-0000-0000-000000000003','im_chat',      now() - interval '9 months'),
 ('44444444-0000-0000-0000-000000000004','absender',     now() - interval '9 months'),
 ('55555555-0000-0000-0000-000000000005','empfaenger',   now() - interval '9 months'),
 ('66666666-0000-0000-0000-000000000006','frisches_ger', now() - interval '9 months'),
 ('77777777-0000-0000-0000-000000000007','partner',      now() - interval '9 months');

-- The ghost: only an ancient push token, nothing else.
INSERT INTO device_tokens (user_id, token, platform, updated_at) VALUES
 ('11111111-0000-0000-0000-000000000001','tok-geist','ios', now() - interval '8 months');
-- The same picture, but the device checked in yesterday.
INSERT INTO device_tokens (user_id, token, platform, updated_at) VALUES
 ('66666666-0000-0000-0000-000000000006','tok-frisch','ios', now() - interval '1 day');

-- Membership protects. `partner` is only the counterpart for the messages below
-- and is protected by those, not by the chat.
INSERT INTO chats (id, name, admins) VALUES
 ('aaaaaaaa-0000-0000-0000-00000000000a','C', ARRAY['33333333-0000-0000-0000-000000000003']::uuid[]);
INSERT INTO chat_members (chat_id, user_id, public_key) VALUES
 ('aaaaaaaa-0000-0000-0000-00000000000a','33333333-0000-0000-0000-000000000003','k');

-- Sent and received respectively — deliberately WITHOUT membership, so that
-- only the message protects the account and not the chat on the side.
INSERT INTO messages (id, chat_id, sender_id, recipient_id, encrypted_content) VALUES
 ('bbbbbbbb-0000-0000-0000-00000000000b','aaaaaaaa-0000-0000-0000-00000000000a',
  '44444444-0000-0000-0000-000000000004','77777777-0000-0000-0000-000000000007','x'),
 ('cccccccc-0000-0000-0000-00000000000c','aaaaaaaa-0000-0000-0000-00000000000a',
  '77777777-0000-0000-0000-000000000007','55555555-0000-0000-0000-000000000005','y');

-- Dry run: does it count without deleting?
SELECT 'trockenlauf_zaehlt=' || purge_dormant_accounts(interval '3 months', true);
SELECT 'trockenlauf_schont=' || count(*) FROM profiles WHERE id = '11111111-0000-0000-0000-000000000001';

-- The rip cord. It is the only reason this function may run unattended at night
-- — so it also has to actually trigger. Both branches are forced via the
-- parameters, so the test does not depend on how many profiles the database
-- happens to contain. It has to stand BEFORE the real run: afterwards there is
-- no hit left, the function would return at 0 immediately and the bound would
-- never come into play.
CREATE TEMP TABLE reissleine(k text);
DO $$
BEGIN
  BEGIN  -- ein Treffer, aber höchstens null dürfen fallen
    PERFORM purge_dormant_accounts(interval '3 months', true, 0, 100);
    INSERT INTO reissleine VALUES ('reissleine_anzahl=0');
  EXCEPTION WHEN others THEN INSERT INTO reissleine VALUES ('reissleine_anzahl=1');
  END;
  BEGIN  -- ein Treffer, aber höchstens 0 % der Instanz
    PERFORM purge_dormant_accounts(interval '3 months', true, 1000, 0);
    INSERT INTO reissleine VALUES ('reissleine_anteil=0');
  EXCEPTION WHEN others THEN INSERT INTO reissleine VALUES ('reissleine_anteil=1');
  END;
END $$;
SELECT k FROM reissleine ORDER BY k;

SELECT 'geloescht=' || purge_dormant_accounts(interval '3 months');

SELECT 'geist_weg='          || count(*) FROM profiles      WHERE id      = '11111111-0000-0000-0000-000000000001';
SELECT 'geist_authuser_weg=' || count(*) FROM auth.users    WHERE id      = '11111111-0000-0000-0000-000000000001';
SELECT 'geist_token_weg='    || count(*) FROM device_tokens WHERE user_id = '11111111-0000-0000-0000-000000000001';

SELECT 'jung_bleibt='            || count(*) FROM profiles WHERE id = '22222222-0000-0000-0000-000000000002';
SELECT 'im_chat_bleibt='         || count(*) FROM profiles WHERE id = '33333333-0000-0000-0000-000000000003';
SELECT 'absender_bleibt='        || count(*) FROM profiles WHERE id = '44444444-0000-0000-0000-000000000004';
SELECT 'empfaenger_bleibt='      || count(*) FROM profiles WHERE id = '55555555-0000-0000-0000-000000000005';
SELECT 'frisches_geraet_bleibt=' || count(*) FROM profiles WHERE id = '66666666-0000-0000-0000-000000000006';

ROLLBACK;
