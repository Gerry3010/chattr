-- 00022: pin search_path on all unpinned trigger functions.
--
-- Found while building delete-account: gotrue's admin deleteUser cascades
-- into public.messages (recipient copies) and public.chats (created_by →
-- NULL). Those cascades fire our notify triggers in the SESSION of
-- supabase_auth_admin, whose default search_path does NOT include `public` —
-- so any SECURITY DEFINER trigger function without a search_path pin that
-- references tables unqualified (e.g. notify_message_delete's
-- `FROM chat_members`) blows up with `relation "chat_members" does not
-- exist`, turning every account deletion into a 500.
--
-- Pin `public, pg_temp` (the 00020 convention) on every trigger function
-- that had no pin. Their cross-schema calls (realtime.send, net.http_post)
-- are already schema-qualified, so the pin is safe.

ALTER FUNCTION notify_admins_pending_member() SET search_path = public, pg_temp;
ALTER FUNCTION notify_chat_delete() SET search_path = public, pg_temp;
ALTER FUNCTION notify_chat_deleted_on_member_removal() SET search_path = public, pg_temp;
ALTER FUNCTION notify_chat_update() SET search_path = public, pg_temp;
ALTER FUNCTION notify_members_new_message() SET search_path = public, pg_temp;
ALTER FUNCTION notify_membership_change() SET search_path = public, pg_temp;
ALTER FUNCTION notify_message_delete() SET search_path = public, pg_temp;
ALTER FUNCTION update_messages_updated_at() SET search_path = public, pg_temp;
