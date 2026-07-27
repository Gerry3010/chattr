-- 00035: Reaction summaries include the reactor user ids.
--
-- Tapping a reaction chip opens chatview's "who reacted" bottom sheet, which
-- lists Reaction.reactedUserIds — the client could never populate it because
-- the summary RPCs only returned emoji + count, so the sheet came up empty.
--
-- The return-type change requires DROP; CREATE OR REPLACE cannot alter the
-- OUT columns of an existing function.
--
-- get_message_reaction_summary also gains the membership check that
-- get_message_reaction_summaries (00026) already had: as SECURITY DEFINER it
-- previously let ANY authenticated user read the reaction summary of ANY
-- message id — with user ids in the payload that would become a real leak.

DROP FUNCTION IF EXISTS get_message_reaction_summary(UUID);

CREATE FUNCTION get_message_reaction_summary(p_message_id UUID)
RETURNS TABLE (
    reaction TEXT,
    count BIGINT,
    user_reacted BOOLEAN,
    user_ids UUID[]
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        mr.reaction,
        COUNT(*)::BIGINT AS count,
        BOOL_OR(mr.user_id = auth.uid()) AS user_reacted,
        ARRAY_AGG(mr.user_id ORDER BY mr.created_at) AS user_ids
    FROM message_reactions mr
    WHERE mr.message_id = p_message_id
      AND EXISTS (
          SELECT 1
          FROM messages m
          JOIN chat_members cm ON cm.chat_id = m.chat_id
          WHERE m.id = mr.message_id
            AND cm.user_id = auth.uid()
      )
    GROUP BY mr.reaction
    ORDER BY COUNT(*) DESC, mr.reaction;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION get_message_reaction_summary(UUID) IS
    'Aggregated reaction counts + reactor user ids for a message; caller must be a member of the message''s chat.';

DROP FUNCTION IF EXISTS get_message_reaction_summaries(UUID[]);

CREATE FUNCTION get_message_reaction_summaries(p_message_ids UUID[])
RETURNS TABLE (
    message_id UUID,
    reaction TEXT,
    count BIGINT,
    user_reacted BOOLEAN,
    user_ids UUID[]
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        mr.message_id,
        mr.reaction,
        COUNT(*)::BIGINT AS count,
        BOOL_OR(mr.user_id = auth.uid()) AS user_reacted,
        ARRAY_AGG(mr.user_id ORDER BY mr.created_at) AS user_ids
    FROM message_reactions mr
    WHERE mr.message_id = ANY(p_message_ids)
      AND EXISTS (
          SELECT 1
          FROM messages m
          JOIN chat_members cm ON cm.chat_id = m.chat_id
          WHERE m.id = mr.message_id
            AND cm.user_id = auth.uid()
      )
    GROUP BY mr.message_id, mr.reaction
    ORDER BY mr.message_id, COUNT(*) DESC, mr.reaction;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION get_message_reaction_summaries(UUID[]) IS
    'Aggregated reaction counts + reactor user ids for many messages at once (chat-open priming); caller must be a member of the messages'' chats.';

-- Self-hosted PostgREST caches the schema; new/changed RPC signatures 404
-- until it reloads.
NOTIFY pgrst, 'reload schema';
