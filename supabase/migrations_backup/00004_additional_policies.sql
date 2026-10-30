-- Migration: Additional RLS Policies
-- Adds missing policies for chats, messages, and profiles

-- 0. Add created_by column to chats table (if not exists)
ALTER TABLE chats 
ADD COLUMN IF NOT EXISTS created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL;

COMMENT ON COLUMN chats.created_by IS 'User who created this chat';

-- Update the trigger to use auth.uid() instead of created_by
CREATE OR REPLACE FUNCTION set_creator_as_admin()
RETURNS TRIGGER AS $$
BEGIN
  -- Set created_by to current user
  NEW.created_by := auth.uid();
  -- Set the creator as the first admin
  NEW.admins := ARRAY[auth.uid()];
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 1. CHATS POLICIES

-- Users can create chats (created_by and admins array will be set by trigger)
DROP POLICY IF EXISTS "Authenticated users can create chats" ON chats;

CREATE POLICY "Authenticated users can create chats"
ON chats FOR INSERT
WITH CHECK (
  auth.uid() IS NOT NULL
);

-- Only admins can delete chats
DROP POLICY IF EXISTS "Admins can delete chats" ON chats;

CREATE POLICY "Admins can delete chats"
ON chats FOR DELETE
USING (
  auth.uid() = ANY(chats.admins)
);

-- 2. MESSAGES POLICIES

-- Messages can only be deleted by the recipient (who received this encrypted copy)
DROP POLICY IF EXISTS "Recipients can delete their messages" ON messages;

CREATE POLICY "Recipients can delete their messages"
ON messages FOR DELETE
USING (
  recipient_id = auth.uid()
);

-- Messages can only be updated by the sender
DROP POLICY IF EXISTS "Senders can update their messages" ON messages;

CREATE POLICY "Senders can update their messages"
ON messages FOR UPDATE
USING (
  sender_id = auth.uid()
)
WITH CHECK (
  sender_id = auth.uid()
);

-- 3. PROFILES POLICIES

-- All authenticated users can view profiles
DROP POLICY IF EXISTS "Authenticated users can view profiles" ON profiles;

CREATE POLICY "Authenticated users can view profiles"
ON profiles FOR SELECT
USING (
  auth.uid() IS NOT NULL
);

-- Users can create their own profile
DROP POLICY IF EXISTS "Users can create their own profile" ON profiles;

CREATE POLICY "Users can create their own profile"
ON profiles FOR INSERT
WITH CHECK (
  auth.uid() = id
);

-- Users can update their own profile
DROP POLICY IF EXISTS "Users can update their own profile" ON profiles;

CREATE POLICY "Users can update their own profile"
ON profiles FOR UPDATE
USING (
  auth.uid() = id
)
WITH CHECK (
  auth.uid() = id
);

-- Users can delete their own profile
DROP POLICY IF EXISTS "Users can delete their own profile" ON profiles;

CREATE POLICY "Users can delete their own profile"
ON profiles FOR DELETE
USING (
  auth.uid() = id
);
