-- SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
-- SPDX-License-Identifier: AGPL-3.0-or-later
--
-- A blob is reaped only once every recipient has KEPT it, not merely seen it.
--
-- Found 2026-10-15: photos and videos turned into endless spinners a day or
-- two after they arrived. The app never stored media: every bubble downloaded
-- and decrypted into memory and dropped the bytes again on scroll. Yet it
-- called mark_media_downloaded on that first in-memory view, and 00056 reaped
-- the blob 24 h after everyone had. From then on nobody had the photo.
--
-- The app now keeps an encrypted copy on the device and reports
-- mark_media_kept only after that copy is complete. The reaper counts only
-- that. mark_media_downloaded stays, because every app out there still calls
-- it, but it no longer counts towards reaping: an app that keeps nothing must
-- not let the server delete the only copy. Its media falls back to the older
-- windows (message gone + 24 h, 3-month cap), as before 00056.

ALTER TABLE public.media_downloads
  ADD COLUMN IF NOT EXISTS kept BOOLEAN NOT NULL DEFAULT false;

COMMENT ON COLUMN public.media_downloads.kept IS
  'The recipient''s device holds a complete local copy (mark_media_kept). Only '
  'kept rows let media_objects_to_reap delete the blob early.';

CREATE OR REPLACE FUNCTION public.mark_media_kept(
  p_message_id UUID,
  p_chat_id UUID
)
RETURNS VOID
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE sql
AS $$
  INSERT INTO public.media_downloads (message_id, recipient_id, kept)
  SELECT p_message_id, auth.uid(), true
  WHERE EXISTS (
    SELECT 1 FROM public.chat_members cm
    WHERE cm.chat_id = p_chat_id
      AND cm.user_id = auth.uid()
  )
  ON CONFLICT (message_id, recipient_id) DO UPDATE SET kept = true;
$$;

COMMENT ON FUNCTION public.mark_media_kept IS
  'Records that the calling recipient''s device now keeps a complete copy of a '
  'media message. Idempotent; no-ops for non-members.';

REVOKE ALL ON FUNCTION public.mark_media_kept(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.mark_media_kept(uuid, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.mark_media_kept(uuid, uuid) TO authenticated;

CREATE OR REPLACE FUNCTION media_objects_to_reap()
RETURNS TABLE(name text)
SECURITY DEFINER
SET search_path = public, pg_temp
LANGUAGE sql
AS $$
  SELECT o.name
  FROM storage.objects o
  WHERE o.bucket_id = 'media'
    AND (
      o.created_at < now() - interval '3 months'
      OR (
        o.created_at < now() - interval '24 hours'
        AND split_part(o.name, '/', 2) ~
          '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'
        AND NOT EXISTS (
          SELECT 1 FROM public.messages m
          WHERE m.id = split_part(o.name, '/', 2)::uuid
        )
      )
      OR (
        o.created_at < now() - interval '24 hours'
        AND split_part(o.name, '/', 2) ~
          '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'
        AND EXISTS (
          SELECT 1 FROM public.messages m
          WHERE m.id = split_part(o.name, '/', 2)::uuid
            AND m.recipient_id IS DISTINCT FROM m.sender_id
        )
        AND NOT EXISTS (
          SELECT 1 FROM public.messages m
          WHERE m.id = split_part(o.name, '/', 2)::uuid
            AND m.recipient_id IS DISTINCT FROM m.sender_id
            AND NOT EXISTS (
              SELECT 1 FROM public.media_downloads d
              WHERE d.message_id = m.id
                AND d.recipient_id = m.recipient_id
                AND d.kept
            )
        )
      )
    );
$$;
