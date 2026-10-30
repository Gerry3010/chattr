-- Test for 00080: `chattr_send` sends exclusively to the private topic.
--
-- Why this needs a check of its own: 00063 introduced the private mirror and
-- DELIBERATELY went on sending to the old public topic, so a client not yet
-- updated would not go mute. That transitional period is over with 00080. The
-- difference between "private, as intended" and "public, as before" is ONE line
-- in a function, and it is visible on no surface: both versions deliver, both
-- feel right. Only the public one lets an arbitrary anonymous subscriber read a
-- stranger's metadata feed — chat_id, sender_id, timestamps, reply graph,
-- reactions.
--
-- So this test does not check the delivery but WHERE it was delivered: exactly
-- one row has to come into being, and it has to be `private`.
--
-- Run: psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \ -v
-- ON_ERROR_STOP=1 -f supabase/tests/legacy_public_topic_gone.sql
--
-- Expected: zeilen_gesamt=1 (the public twin is gone) davon_privat=1 (and the
-- remaining one is the private one) davon_oeffentlich=0 (the actual promise)
-- topic_hat_praefix=1 (p:<topic>, not the bare name)

BEGIN;

SELECT public.chattr_send(
  '{"type":"testprobe_00080"}'::jsonb,
  'event',
  'user:99999999-0000-0000-0000-0000000000aa',
  FALSE
);

SELECT 'zeilen_gesamt=' || count(*) FROM realtime.messages
 WHERE payload::text LIKE '%testprobe_00080%';

SELECT 'davon_privat=' || count(*) FROM realtime.messages
 WHERE payload::text LIKE '%testprobe_00080%' AND private IS TRUE;

-- The row this is about. If a 1 ever stands here again, the legacy send is back
-- — presumably because somebody ran 00063 again.
SELECT 'davon_oeffentlich=' || count(*) FROM realtime.messages
 WHERE payload::text LIKE '%testprobe_00080%' AND private IS FALSE;

SELECT 'topic_hat_praefix=' || count(*) FROM realtime.messages
 WHERE payload::text LIKE '%testprobe_00080%'
   AND topic = 'p:user:99999999-0000-0000-0000-0000000000aa';

ROLLBACK;
