-- =====================================================
-- Message Reactions
-- =====================================================
-- This migration adds emoji reactions to messages

-- Create message_reactions table
CREATE TABLE IF NOT EXISTS message_reactions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    message_id UUID NOT NULL,  -- References logical message ID (not FK due to composite PK in messages)
    user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    reaction TEXT NOT NULL CHECK (length(reaction) > 0 AND length(reaction) <= 10),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- One user can only react with the same emoji once per message
    UNIQUE (message_id, user_id, reaction)
);

-- Create indexes for better performance
CREATE INDEX IF NOT EXISTS idx_message_reactions_message_id ON message_reactions(message_id);
CREATE INDEX IF NOT EXISTS idx_message_reactions_user_id ON message_reactions(user_id);
CREATE INDEX IF NOT EXISTS idx_message_reactions_created_at ON message_reactions(created_at DESC);

-- Enable RLS
ALTER TABLE message_reactions ENABLE ROW LEVEL SECURITY;

-- Set REPLICA IDENTITY FULL to receive full row data in DELETE events
ALTER TABLE message_reactions REPLICA IDENTITY FULL;

-- =====================================================
-- RLS Policies
-- =====================================================

-- Users can see reactions on messages in their chats
CREATE POLICY "Users can view reactions in their chats"
    ON message_reactions
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM messages m
            JOIN chat_members cm ON cm.chat_id = m.chat_id
            WHERE m.id = message_reactions.message_id
            AND cm.user_id = auth.uid()
        )
    );

-- Users can add reactions to messages in their chats
CREATE POLICY "Users can add reactions in their chats"
    ON message_reactions
    FOR INSERT
    WITH CHECK (
        user_id = auth.uid()
        AND EXISTS (
            SELECT 1 FROM messages m
            JOIN chat_members cm ON cm.chat_id = m.chat_id
            WHERE m.id = message_reactions.message_id
            AND cm.user_id = auth.uid()
        )
    );

-- Users can only delete their own reactions
CREATE POLICY "Users can delete own reactions"
    ON message_reactions
    FOR DELETE
    USING (user_id = auth.uid());

-- =====================================================
-- Functions
-- =====================================================

-- Get reaction summary for a message (grouped by emoji)
CREATE OR REPLACE FUNCTION get_message_reaction_summary(p_message_id UUID)
RETURNS TABLE (
    reaction TEXT,
    count BIGINT,
    user_reacted BOOLEAN
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        mr.reaction,
        COUNT(*)::BIGINT as count,
        BOOL_OR(mr.user_id = auth.uid()) as user_reacted
    FROM message_reactions mr
    WHERE mr.message_id = p_message_id
    GROUP BY mr.reaction
    ORDER BY COUNT(*) DESC, mr.reaction;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Toggle reaction (add if not exists, remove if exists)
CREATE OR REPLACE FUNCTION toggle_message_reaction(
    p_message_id UUID,
    p_reaction TEXT
)
RETURNS BOOLEAN AS $$
DECLARE
    v_exists BOOLEAN;
BEGIN
    -- Check if reaction already exists
    SELECT EXISTS (
        SELECT 1 FROM message_reactions
        WHERE message_id = p_message_id
        AND user_id = auth.uid()
        AND reaction = p_reaction
    ) INTO v_exists;
    
    IF v_exists THEN
        -- Remove reaction
        DELETE FROM message_reactions
        WHERE message_id = p_message_id
        AND user_id = auth.uid()
        AND reaction = p_reaction;
        
        RETURN FALSE; -- Removed
    ELSE
        -- Add reaction (will fail if user is not in chat due to RLS)
        INSERT INTO message_reactions (message_id, user_id, reaction)
        VALUES (p_message_id, auth.uid(), p_reaction);
        
        RETURN TRUE; -- Added
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Get users who reacted with a specific emoji
CREATE OR REPLACE FUNCTION get_reaction_users(
    p_message_id UUID,
    p_reaction TEXT
)
RETURNS TABLE (
    user_id UUID,
    username TEXT,
    created_at TIMESTAMPTZ
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        mr.user_id,
        p.username,
        mr.created_at
    FROM message_reactions mr
    JOIN profiles p ON p.id = mr.user_id
    WHERE mr.message_id = p_message_id
    AND mr.reaction = p_reaction
    ORDER BY mr.created_at ASC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- =====================================================
-- Realtime Publication
-- =====================================================

-- Enable realtime for message_reactions
ALTER PUBLICATION supabase_realtime ADD TABLE message_reactions;

-- =====================================================
-- Comments
-- =====================================================

COMMENT ON TABLE message_reactions IS 'Emoji reactions on messages - not encrypted';
COMMENT ON FUNCTION get_message_reaction_summary(UUID) IS 'Returns aggregated reaction counts for a message';
COMMENT ON FUNCTION toggle_message_reaction(UUID, TEXT) IS 'Adds or removes a reaction (toggle behavior)';
COMMENT ON FUNCTION get_reaction_users(UUID, TEXT) IS 'Returns list of users who reacted with a specific emoji';
