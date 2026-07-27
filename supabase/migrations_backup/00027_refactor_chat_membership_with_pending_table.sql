-- Refactor chat membership system with separate pending_chat_members table
-- This provides better separation of concerns and clearer RLS policies

-- =============================================================================
-- PART 1: Create pending_chat_members table
-- =============================================================================

CREATE TABLE pending_chat_members (
  chat_id UUID NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  public_key TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  blocked_at TIMESTAMPTZ,
  PRIMARY KEY (chat_id, user_id)
);

-- Create indexes for performance
CREATE INDEX idx_pending_chat_members_chat_id ON pending_chat_members(chat_id);
CREATE INDEX idx_pending_chat_members_user_id ON pending_chat_members(user_id);
CREATE INDEX idx_pending_chat_members_created_at ON pending_chat_members(created_at);

-- Add trigger to automatically update updated_at
CREATE OR REPLACE FUNCTION update_pending_members_updated_at()
RETURNS TRIGGER
SECURITY DEFINER
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER pending_members_updated_at_trigger
BEFORE UPDATE ON pending_chat_members
FOR EACH ROW
EXECUTE FUNCTION update_pending_members_updated_at();

-- Enable RLS
ALTER TABLE pending_chat_members ENABLE ROW LEVEL SECURITY;

-- RLS Policies for pending_chat_members:
-- 1. Users can insert their own pending membership requests
CREATE POLICY "Users can request to join chats"
ON pending_chat_members
FOR INSERT
TO authenticated
WITH CHECK (auth.uid() = user_id);

-- 2. Users can view their own pending requests
CREATE POLICY "Users can view own pending requests"
ON pending_chat_members
FOR SELECT
TO authenticated
USING (auth.uid() = user_id);

-- 3. Chat admins can view all pending requests for their chats
CREATE POLICY "Admins can view pending requests"
ON pending_chat_members
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM chats
    WHERE chats.id = pending_chat_members.chat_id
    AND auth.uid() = ANY(chats.admins)
  )
);

-- 4. Chat admins can update pending requests (e.g., block)
CREATE POLICY "Admins can update pending requests"
ON pending_chat_members
FOR UPDATE
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM chats
    WHERE chats.id = pending_chat_members.chat_id
    AND auth.uid() = ANY(chats.admins)
  )
);

-- 5. Chat admins can delete pending requests (approve or reject)
CREATE POLICY "Admins can delete pending requests"
ON pending_chat_members
FOR DELETE
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM chats
    WHERE chats.id = pending_chat_members.chat_id
    AND auth.uid() = ANY(chats.admins)
  )
);

COMMENT ON TABLE pending_chat_members IS 'Stores pending chat membership requests before admin approval';

-- =============================================================================
-- PART 2: Update chat_members table
-- =============================================================================

-- First, drop the trigger that depends on the accepted column
DROP TRIGGER IF EXISTS on_member_status_change ON chat_members;

-- Drop and recreate the messages insert policy that depends on accepted column
DROP POLICY IF EXISTS "Users can insert messages in their chats" ON messages;

CREATE POLICY "Users can insert messages in their chats"
ON messages FOR INSERT
WITH CHECK (
  sender_id = auth.uid()
  AND EXISTS (
    SELECT 1 FROM chat_members
    WHERE chat_members.chat_id = messages.chat_id
    AND chat_members.user_id = auth.uid()
  )
);

-- Now we can safely drop the accepted column (no longer needed with separate pending table)
ALTER TABLE chat_members DROP COLUMN IF EXISTS accepted;

-- Drop old policies
DROP POLICY IF EXISTS "Users can view chat members" ON chat_members;
DROP POLICY IF EXISTS "Users can add themselves to chats" ON chat_members;
DROP POLICY IF EXISTS "Chat admins can manage members" ON chat_members;
DROP POLICY IF EXISTS "Users can update their own public key" ON chat_members;
DROP POLICY IF EXISTS "Users can remove themselves from chats" ON chat_members;

-- New RLS Policies for chat_members:
-- 1. Members can view all members of chats they belong to
CREATE POLICY "Members can view chat members"
ON chat_members
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM chat_members AS cm
    WHERE cm.chat_id = chat_members.chat_id
    AND cm.user_id = auth.uid()
  )
);

-- 2. Only admins can insert new members (after approval)
CREATE POLICY "Admins can add members"
ON chat_members
FOR INSERT
TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1 FROM chats
    WHERE chats.id = chat_id
    AND auth.uid() = ANY(chats.admins)
  )
);

-- 3. Admins can update any member
CREATE POLICY "Admins can update members"
ON chat_members
FOR UPDATE
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM chats
    WHERE chats.id = chat_members.chat_id
    AND auth.uid() = ANY(chats.admins)
  )
);

-- 4. Members can update their own record (e.g., public key)
CREATE POLICY "Members can update own record"
ON chat_members
FOR UPDATE
TO authenticated
USING (auth.uid() = user_id);

-- 5. Admins can remove any member
CREATE POLICY "Admins can remove members"
ON chat_members
FOR DELETE
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM chats
    WHERE chats.id = chat_members.chat_id
    AND auth.uid() = ANY(chats.admins)
  )
);

-- 6. Members can remove themselves (leave chat)
CREATE POLICY "Members can leave chat"
ON chat_members
FOR DELETE
TO authenticated
USING (auth.uid() = user_id);

-- =============================================================================
-- PART 3: Update triggers for new membership flow
-- =============================================================================

-- Update notify_admins_pending_member to work with new table
DROP TRIGGER IF EXISTS notify_admins_pending_member_trigger ON chat_members;
DROP FUNCTION IF EXISTS notify_admins_pending_member();

CREATE OR REPLACE FUNCTION notify_admins_pending_member()
RETURNS TRIGGER
SECURITY DEFINER
AS $$
DECLARE
  admin_id TEXT;
  chat_admins TEXT[];
  chat_name TEXT;
  requester_name TEXT;
  admin_uuids UUID[];
  function_url TEXT;
BEGIN
  -- Get the list of admins for this chat
  SELECT admins INTO chat_admins
  FROM chats
  WHERE id = NEW.chat_id;

  -- Get chat name and requester username
  SELECT name INTO chat_name FROM chats WHERE id = NEW.chat_id;
  SELECT username INTO requester_name FROM profiles WHERE id = NEW.user_id;
  
  chat_name := COALESCE(chat_name, 'Chat');
  requester_name := COALESCE(requester_name, 'Someone');

  -- Send realtime notifications to each admin
  IF chat_admins IS NOT NULL THEN
    FOREACH admin_id IN ARRAY chat_admins
    LOOP
      PERFORM realtime.send(
        jsonb_build_object(
          'type', 'pendingMember',
          'chat_id', NEW.chat_id,
          'user_id', NEW.user_id,
          'timestamp', NOW()
        ),
        'event',
        'user:' || admin_id,
        FALSE
      );
    END LOOP;

    -- Convert TEXT[] to UUID[] for push notifications
    admin_uuids := (
      SELECT ARRAY_AGG(aid::uuid)
      FROM unnest(chat_admins) AS aid
    );

    -- Send push notifications
    IF admin_uuids IS NOT NULL AND array_length(admin_uuids, 1) > 0 THEN
      function_url := COALESCE(
        current_setting('app.settings.edge_function_url', true),
        'http://kong:8000/functions/v1/send-push-notification'
      );

      BEGIN
        PERFORM net.http_post(
          url := function_url,
          headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'Authorization', 'Bearer ' || private.get_secret('service_role_key')
          ),
          body := jsonb_build_object(
            'type', 'member_request',
            'user_ids', admin_uuids,
            'title', 'New Join Request',
            'body', requester_name || ' wants to join ' || chat_name,
            'data', jsonb_build_object(
              'chat_id', NEW.chat_id::text,
              'requester_id', NEW.user_id::text,
              'requester_name', requester_name
            )
          )
        );
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'Failed to send push notification: %', SQLERRM;
      END;
    END IF;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create trigger on pending_chat_members
CREATE TRIGGER notify_admins_pending_member_trigger
AFTER INSERT ON pending_chat_members
FOR EACH ROW
EXECUTE FUNCTION notify_admins_pending_member();

-- Update notify_member_status_change to work with chat_members only
-- (This trigger is no longer needed as approval creates the member directly)
DROP TRIGGER IF EXISTS notify_member_status_change_trigger ON chat_members;
DROP FUNCTION IF EXISTS notify_member_status_change();

-- Update notify_membership_change to only trigger on chat_members
-- (It already handles INSERT/DELETE correctly)
DROP TRIGGER IF EXISTS notify_membership_change_trigger ON chat_members;
CREATE TRIGGER notify_membership_change_trigger
AFTER INSERT OR DELETE ON chat_members
FOR EACH ROW
EXECUTE FUNCTION notify_membership_change();

COMMENT ON FUNCTION notify_admins_pending_member IS 'Notifies admins when a user requests to join via pending_chat_members';
COMMENT ON FUNCTION notify_membership_change IS 'Notifies members about membership changes (joined/left) on chat_members table';
