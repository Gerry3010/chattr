-- ============================================================================
-- 00016: Encrypted media sharing
-- ----------------------------------------------------------------------------
-- File sharing (photo/video/audio/files) stays end-to-end encrypted: the file
-- bytes are encrypted client-side with a fresh AES key (the media key), and
-- only the CIPHERTEXT is uploaded here. The media key + metadata travel inside
-- the per-recipient message envelope (encrypted_content), wrapped with each
-- recipient's hybrid public key exactly like a text message. So the server
-- holds only opaque ciphertext blobs and never a usable key.
--
-- Bucket is PRIVATE; only chat members may read/write objects under their
-- chat's folder. Object path: `<chatId>/<messageId>/<filename>.enc`.
-- ============================================================================

INSERT INTO storage.buckets (id, name, public)
VALUES ('media', 'media', false)
ON CONFLICT (id) DO UPDATE SET public = false;

-- Members of a chat may read its media objects.
DROP POLICY IF EXISTS "Chat members read media" ON storage.objects;
CREATE POLICY "Chat members read media"
ON storage.objects FOR SELECT
USING (
  bucket_id = 'media'
  AND EXISTS (
    SELECT 1 FROM chat_members cm
    WHERE cm.chat_id::text = (storage.foldername(name))[1]
      AND cm.user_id = auth.uid()
  )
);

-- Members of a chat may upload media into its folder.
DROP POLICY IF EXISTS "Chat members write media" ON storage.objects;
CREATE POLICY "Chat members write media"
ON storage.objects FOR INSERT
WITH CHECK (
  bucket_id = 'media'
  AND EXISTS (
    SELECT 1 FROM chat_members cm
    WHERE cm.chat_id::text = (storage.foldername(name))[1]
      AND cm.user_id = auth.uid()
  )
);

-- The uploader may delete their own objects (e.g. on send failure / unsend).
DROP POLICY IF EXISTS "Uploader deletes own media" ON storage.objects;
CREATE POLICY "Uploader deletes own media"
ON storage.objects FOR DELETE
USING (bucket_id = 'media' AND owner = auth.uid());
