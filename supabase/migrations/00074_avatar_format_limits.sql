-- ============================================================================
-- 00074: the avatar buckets accept only displayable formats
-- ----------------------------------------------------------------------------
-- Finding (2026-08-13): in `avatars` and `group-avatars` there were three
-- objects called `avatar.heic` — HEIC bytes, labelled as `image/jpeg`. The
-- cause was the client rule "extension → content type, otherwise assume JPEG"
-- (`avatar_actions.dart`): `heic` was not in the table, so it silently got the
-- wrong label. The consequence: every device without an Apple decoder — Android
-- < 10, Linux, every browser — does not display these profile pictures at all,
-- and the content type lies on top of it.
--
-- The client now decides the format from the magic bytes and converts phone
-- captures to JPEG on selection (`avatar_image_pick.dart`). This migration is
-- the belt to that pair of braces: the server no longer accepts anything else.
-- A client with a bug can no longer deposit an unreadable avatar, nor can an
-- older version.
--
-- Plus a size limit. One profile picture in production was 3.1 MB — it is
-- loaded again by every viewer, permanently. 2 MiB is plenty for an image
-- stored with an edge length of at most 1024 px.
--
-- CAUTION for later migrations and fresh setups: 00015 (line 23) and 00055
-- (line 93) contain `ON CONFLICT (id) DO UPDATE SET public = true`. Whoever
-- runs them again makes the buckets publicly readable once more and does NOT
-- reset the limits here — those remain. When closing the store (signed
-- addresses), that is the point to look at.
-- ============================================================================

UPDATE storage.buckets
   SET allowed_mime_types = ARRAY[
         'image/jpeg',
         'image/png',
         'image/webp',
         'image/gif'
       ],
       -- 2 MiB. The client aims at considerably less (512 KiB, otherwise it
       -- scales the image down); this limit only catches the failure case.
       file_size_limit = 2097152
 WHERE id IN ('avatars', 'group-avatars');

COMMENT ON TABLE storage.buckets IS
  'Storage-Buckets. avatars/group-avatars sind auf anzeigbare Bildformate und 2 MiB begrenzt (00074) — HEIC ist bewusst NICHT dabei, siehe Migrationskopf.';
