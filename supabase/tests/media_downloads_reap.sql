-- Media-retention v3 (00056): a blob is reaped once EVERY recipient (excluding
-- the sender's own copy) has confirmed a download — decoupled from read
-- receipts — after the 24h grace. mark_media_downloaded writes exactly one
-- recipient row and is idempotent.
--
-- Run: psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--        -v ON_ERROR_STOP=1 -f supabase/tests/media_downloads_reap.sql
--
-- Expected:
--   bob_rows=1              (one download row for bob)
--   idempotent_rows=1       (a second mark_media_downloaded adds nothing)
--   reap_before_any=0       (no downloads → not reaped)
--   reap_bob_only=0         (only bob downloaded → carol still pending → not reaped)
--   reap_all=1              (bob AND carol downloaded → reaped, alice's own copy ignored)
--   reap_fresh=0            (< 24h old blob is never reaped early, even fully downloaded)

BEGIN;

-- alice = sender, bob + carol = recipients.
INSERT INTO auth.users (id, instance_id, aud, role, email) VALUES
 ('aaaaaaa1-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000000','authenticated','authenticated','a@t.de'),
 ('bbbbbbb2-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000000','authenticated','authenticated','b@t.de'),
 ('ccccccc3-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000000','authenticated','authenticated','c@t.de');
INSERT INTO profiles (id, username) VALUES
 ('aaaaaaa1-0000-0000-0000-000000000001','alice'),
 ('bbbbbbb2-0000-0000-0000-000000000002','bob'),
 ('ccccccc3-0000-0000-0000-000000000003','carol');
INSERT INTO chats (id, name, admins) VALUES
 ('ddddddd4-0000-0000-0000-000000000004','C', ARRAY['aaaaaaa1-0000-0000-0000-000000000001']::uuid[]);
INSERT INTO chat_members (chat_id, user_id, public_key) VALUES
 ('ddddddd4-0000-0000-0000-000000000004','aaaaaaa1-0000-0000-0000-000000000001','k'),
 ('ddddddd4-0000-0000-0000-000000000004','bbbbbbb2-0000-0000-0000-000000000002','k'),
 ('ddddddd4-0000-0000-0000-000000000004','ccccccc3-0000-0000-0000-000000000003','k');

-- A media message: one row per recipient PLUS alice's own copy (sender=recipient).
INSERT INTO messages (id, chat_id, sender_id, recipient_id, encrypted_content) VALUES
 ('eeeeeee5-0000-0000-0000-000000000005','ddddddd4-0000-0000-0000-000000000004','aaaaaaa1-0000-0000-0000-000000000001','aaaaaaa1-0000-0000-0000-000000000001',''),
 ('eeeeeee5-0000-0000-0000-000000000005','ddddddd4-0000-0000-0000-000000000004','aaaaaaa1-0000-0000-0000-000000000001','bbbbbbb2-0000-0000-0000-000000000002',''),
 ('eeeeeee5-0000-0000-0000-000000000005','ddddddd4-0000-0000-0000-000000000004','aaaaaaa1-0000-0000-0000-000000000001','ccccccc3-0000-0000-0000-000000000003','');

-- The stored blob: path <chatId>/<messageId>/media-0.enc, aged past the 24h grace.
INSERT INTO storage.objects (bucket_id, name, created_at) VALUES
 ('media','ddddddd4-0000-0000-0000-000000000004/eeeeeee5-0000-0000-0000-000000000005/media-0.enc', now() - interval '2 days');

-- (A) No downloads yet → not reaped.
SELECT 'reap_before_any=' || count(*) FROM media_objects_to_reap()
 WHERE name LIKE '%eeeeeee5%';

-- Bob confirms his download (as bob).
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" = '{"sub":"bbbbbbb2-0000-0000-0000-000000000002","role":"authenticated"}';
SELECT mark_media_downloaded('eeeeeee5-0000-0000-0000-000000000005','ddddddd4-0000-0000-0000-000000000004');
-- Idempotent: a repeat adds nothing.
SELECT mark_media_downloaded('eeeeeee5-0000-0000-0000-000000000005','ddddddd4-0000-0000-0000-000000000004');
RESET ROLE;

SELECT 'bob_rows=' || count(*) FROM media_downloads
 WHERE message_id='eeeeeee5-0000-0000-0000-000000000005'
   AND recipient_id='bbbbbbb2-0000-0000-0000-000000000002';
SELECT 'idempotent_rows=' || count(*) FROM media_downloads
 WHERE message_id='eeeeeee5-0000-0000-0000-000000000005';

-- (B) Only bob downloaded, carol still pending → not reaped.
SELECT 'reap_bob_only=' || count(*) FROM media_objects_to_reap()
 WHERE name LIKE '%eeeeeee5%';

-- Carol confirms too.
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" = '{"sub":"ccccccc3-0000-0000-0000-000000000003","role":"authenticated"}';
SELECT mark_media_downloaded('eeeeeee5-0000-0000-0000-000000000005','ddddddd4-0000-0000-0000-000000000004');
RESET ROLE;

-- (C) Both recipients downloaded (alice's own copy is excluded) → reaped.
SELECT 'reap_all=' || count(*) FROM media_objects_to_reap()
 WHERE name LIKE '%eeeeeee5%';

-- (D) A brand-new blob (inside the 24h grace) is never reaped early, even fully
--     downloaded.
INSERT INTO storage.objects (bucket_id, name, created_at) VALUES
 ('media','ddddddd4-0000-0000-0000-000000000004/eeeeeee5-0000-0000-0000-000000000005/media-1.enc', now() - interval '1 hour');
SELECT 'reap_fresh=' || count(*) FROM media_objects_to_reap()
 WHERE name LIKE '%media-1.enc';

ROLLBACK;
