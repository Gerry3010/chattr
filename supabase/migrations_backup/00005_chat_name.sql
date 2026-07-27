-- Migration: Add optional name column to chats
-- Allows naming group chats while keeping it optional for individual chats

-- 1. Add name column (nullable)
ALTER TABLE chats 
ADD COLUMN name TEXT DEFAULT NULL;

COMMENT ON COLUMN chats.name IS 'Optional name for the chat (typically used for group chats)';

-- 2. Update RLS policy: Only admins can update chat name
-- Modify existing admin policy to include name updates
DROP POLICY IF EXISTS "Admins can manage chat admins" ON chats;

CREATE POLICY "Admins can manage chat properties"
ON chats FOR UPDATE
USING (
  auth.uid() = ANY(chats.admins)
)
WITH CHECK (
  auth.uid() = ANY(chats.admins)
);

COMMENT ON POLICY "Admins can manage chat properties" ON chats IS 'Admins can update chat name, admins array, and other admin-controlled properties';
