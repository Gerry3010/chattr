-- 00026: Batched reaction summaries for priming a whole chat's reactions.
--
-- The client used to prime reactions with a direct SELECT on
-- message_reactions, but its RLS policy checks visibility through the
-- messages table, whose SELECT policy is recipient-only — a sender has no
-- row for their own sent messages, so reactions ON YOUR OWN MESSAGES were
-- invisible to the batch query (they only appeared via live events).
-- SECURITY DEFINER sidesteps that, like get_message_reaction_summary does;
-- membership is checked explicitly.

CREATE OR REPLACE FUNCTION get_message_reaction_summaries(p_message_ids UUID[])
RETURNS TABLE (
    message_id UUID,
    reaction TEXT,
    count BIGINT,
    user_reacted BOOLEAN
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        mr.message_id,
        mr.reaction,
        COUNT(*)::BIGINT AS count,
        BOOL_OR(mr.user_id = auth.uid()) AS user_reacted
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
    'Aggregated reaction counts for many messages at once (chat-open priming); caller must be a member of the messages'' chats.';
