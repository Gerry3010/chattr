-- SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
-- SPDX-License-Identifier: AGPL-3.0-or-later
--
-- 00094: who may see a profile picture, and four small hardenings from the
-- security check of 2026-10-25.
--
-- (Not here: taking `net` away from anon/authenticated (CHAT-21). Those
-- grants belong to supabase_admin, and the migration role cannot revoke them;
-- the statement only warns and changes nothing. A one-off as supabase_admin.)
--
-- 1. Profile and group pictures (CHAT-18). Reading `avatars` and
--    `group-avatars` needed nothing but a signed-in session (00078), and
--    signing in is anonymous and open: a throwaway account could list the
--    bucket and get the folder name of every user with a picture, which is
--    their user id. That is the directory 00046 closed for `profiles`. A
--    picture is now readable by those who may see the profile
--    (`can_view_profile`) and by the person an open chat request is aimed at
--    (they need the picture to decide, see 00082). Group pictures by members
--    and by pending joiners of that chat.
--
-- 2. Notices posing as Chattr (CHAT-39, C3). The insert policy did not look at
--    `message_type`, so a member could insert a row typed `system`. Real
--    notices come from the edge function with the service role, past RLS.
--    (The clients also stopped trusting the type on its own.)
--
-- 3. Direct UPDATE of messages by the sender (CHAT-21). No client updates a
--    message row directly; editing goes through `edit_message` (00090), which
--    keeps the edit window. The open policy let a sender rewrite any column of
--    their rows, the ciphertext outside that window included.
--
-- 4. Invisible characters in usernames (CHAT-42). Zero-width characters and
--    direction overrides make one name look like another. NOT VALID: existing
--    names stay as they are, new ones and renames are checked. The app has
--    rejected them since the same release.

-- ── 1. Pictures ──────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.can_view_avatar_folder(p_folder text)
  RETURNS boolean
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path = public, pg_temp
AS $function$
  SELECT CASE
    WHEN p_folder ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' THEN
      public.can_view_profile(p_folder::uuid)
      OR EXISTS (
        SELECT 1
        FROM public.chat_requests r
        WHERE r.requester_id = p_folder::uuid
          AND r.target_id = auth.uid()
          AND r.accepted IS NULL
      )
    ELSE false
  END;
$function$;

REVOKE EXECUTE ON FUNCTION public.can_view_avatar_folder(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.can_view_avatar_folder(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.can_view_group_avatar_folder(p_folder text)
  RETURNS boolean
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path = public, pg_temp
AS $function$
  SELECT CASE
    WHEN p_folder ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' THEN
      EXISTS (
        SELECT 1 FROM public.chat_members m
        WHERE m.chat_id = p_folder::uuid AND m.user_id = auth.uid()
      )
      OR EXISTS (
        SELECT 1 FROM public.pending_chat_members p
        WHERE p.chat_id = p_folder::uuid AND p.user_id = auth.uid()
      )
    ELSE false
  END;
$function$;

REVOKE EXECUTE ON FUNCTION public.can_view_group_avatar_folder(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.can_view_group_avatar_folder(text) TO authenticated;

-- `objects.name` qualified: an unqualified `name` resolved to another column
-- inside storage policies once already (00055).
DROP POLICY IF EXISTS "Avatars are readable by signed-in users" ON storage.objects;
DROP POLICY IF EXISTS "Avatars are readable by those who may see the profile" ON storage.objects;
CREATE POLICY "Avatars are readable by those who may see the profile"
ON storage.objects FOR SELECT
TO authenticated
USING (
  bucket_id = 'avatars'
  AND public.can_view_avatar_folder((storage.foldername(objects.name))[1])
);

DROP POLICY IF EXISTS "Group avatars are readable by signed-in users" ON storage.objects;
DROP POLICY IF EXISTS "Group avatars are readable by members" ON storage.objects;
CREATE POLICY "Group avatars are readable by members"
ON storage.objects FOR SELECT
TO authenticated
USING (
  bucket_id = 'group-avatars'
  AND public.can_view_group_avatar_folder((storage.foldername(objects.name))[1])
);

-- ── 2. Only Chattr writes notices ────────────────────────────────────────

DO $$
DECLARE
  v_check text;
BEGIN
  SELECT pg_get_expr(polwithcheck, polrelid) INTO v_check
  FROM pg_policy
  WHERE polrelid = 'public.messages'::regclass
    AND polname = 'Users can insert messages for all chat members';
  IF v_check IS NULL THEN
    RAISE EXCEPTION 'insert policy on messages not found';
  END IF;
  EXECUTE 'DROP POLICY "Users can insert messages for all chat members" ON public.messages';
  EXECUTE format(
    'CREATE POLICY "Users can insert messages for all chat members" ON public.messages '
    'FOR INSERT WITH CHECK ((%s) AND message_type IN (''user'', ''summary''))',
    v_check
  );
END;
$$;

-- ── 3. No direct UPDATE by the sender ────────────────────────────────────

DROP POLICY IF EXISTS "Senders can update their messages" ON public.messages;

-- ── 4. No invisible characters in new usernames ──────────────────────────

ALTER TABLE public.profiles DROP CONSTRAINT IF EXISTS profiles_username_visible;
ALTER TABLE public.profiles
  ADD CONSTRAINT profiles_username_visible
  CHECK (username !~ '[​-‏‪-‮⁠-⁤⁦-⁩﻿]')
  NOT VALID;

NOTIFY pgrst, 'reload schema';
