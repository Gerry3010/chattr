-- ============================================================================
-- 00015: Profile avatars
-- ----------------------------------------------------------------------------
-- Stage 8.1 — optional profile pictures. Avatars are deliberately stored in a
-- PUBLIC storage bucket (usernames are already shared via QR to start a chat,
-- so the avatar carries no more identity than that). The message *content*
-- stays end-to-end encrypted; only the avatar image is public.
--
-- Each user owns the folder named after their auth uid: `<uid>/<file>`. The
-- profile row keeps `avatar_path` (the object path); clients build the public
-- URL from it.
-- ============================================================================

ALTER TABLE profiles
  ADD COLUMN IF NOT EXISTS avatar_path text;

COMMENT ON COLUMN profiles.avatar_path IS
  'Storage object path of the profile avatar (bucket "avatars"), or NULL.';

-- Public avatars bucket (idempotent).
INSERT INTO storage.buckets (id, name, public)
VALUES ('avatars', 'avatars', true)
ON CONFLICT (id) DO UPDATE SET public = true;

-- Anyone may read avatars (public bucket).
DROP POLICY IF EXISTS "Avatars are publicly readable" ON storage.objects;
CREATE POLICY "Avatars are publicly readable"
ON storage.objects FOR SELECT
USING (bucket_id = 'avatars');

-- A user may only write/replace/delete objects inside their own uid folder.
DROP POLICY IF EXISTS "Users manage their own avatar" ON storage.objects;
CREATE POLICY "Users manage their own avatar"
ON storage.objects FOR ALL
USING (
  bucket_id = 'avatars'
  AND (storage.foldername(name))[1] = auth.uid()::text
)
WITH CHECK (
  bucket_id = 'avatars'
  AND (storage.foldername(name))[1] = auth.uid()::text
);
