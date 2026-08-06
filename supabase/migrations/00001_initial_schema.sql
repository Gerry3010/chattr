-- ============================================================================
-- Initial Database Schema
-- ============================================================================
-- This migration creates all tables, indexes, constraints, and foreign keys
-- for the chat application with end-to-end encryption support.
--
-- Tables:
-- - profiles: User profiles
-- - chats: Chat rooms (both group and 1:1)
-- - chat_members: Approved members of chats
-- - pending_chat_members: Pending membership requests awaiting admin approval
-- - messages: Encrypted messages
-- - device_tokens: FCM tokens for push notifications
-- ============================================================================

-- ============================================================================
-- PART 1: Profiles Table
-- ============================================================================

CREATE TABLE profiles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  username TEXT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE profiles IS 'User profiles with RLS enabled';

-- ============================================================================
-- PART 2: Chats Table
-- ============================================================================

CREATE TABLE chats (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  name TEXT,
  is_group BOOLEAN NOT NULL DEFAULT true,
  admins UUID[] DEFAULT ARRAY[]::UUID[]
);

COMMENT ON TABLE chats IS 'Chat rooms with RLS enabled';
COMMENT ON COLUMN chats.created_by IS 'User who created this chat';
COMMENT ON COLUMN chats.name IS 'Optional name for the chat (typically used for group chats)';
COMMENT ON COLUMN chats.is_group IS 'Whether this is a group chat (true) or a direct 1:1 chat (false)';
COMMENT ON COLUMN chats.admins IS 'Array of user IDs who are admins of this chat';
COMMENT ON COLUMN chats.updated_at IS 'Timestamp when the chat was last updated';

-- ============================================================================
-- PART 3: Chat Members Table
-- ============================================================================

CREATE TABLE chat_members (
  chat_id UUID NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  public_key TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (chat_id, user_id)
);

COMMENT ON TABLE chat_members IS 'Members of chats who have been approved by admins';
COMMENT ON COLUMN chat_members.public_key IS 'RSA public key (PEM format) for this member in this chat';
COMMENT ON COLUMN chat_members.created_at IS 'When the member was added to the chat';
COMMENT ON COLUMN chat_members.updated_at IS 'When the member record was last updated';

-- Create index for public key lookups
CREATE INDEX idx_chat_members_public_key ON chat_members (chat_id, user_id) WHERE public_key IS NOT NULL;

-- ============================================================================
-- PART 4: Pending Chat Members Table
-- ============================================================================

CREATE TABLE pending_chat_members (
  chat_id UUID NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  public_key TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  blocked_at TIMESTAMPTZ,
  PRIMARY KEY (chat_id, user_id)
);

COMMENT ON TABLE pending_chat_members IS 'Pending membership requests awaiting admin approval';

-- Create indexes for performance
CREATE INDEX idx_pending_chat_members_chat_id ON pending_chat_members(chat_id);
CREATE INDEX idx_pending_chat_members_user_id ON pending_chat_members(user_id);
CREATE INDEX idx_pending_chat_members_created_at ON pending_chat_members(created_at);

-- ============================================================================
-- PART 5: Messages Table
-- ============================================================================

CREATE TABLE messages (
  id UUID NOT NULL,
  chat_id UUID NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  sender_id UUID REFERENCES profiles(id),
  recipient_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  encrypted_content TEXT NOT NULL,
  message_type TEXT NOT NULL DEFAULT 'user',
  created_at TIMESTAMPTZ DEFAULT NOW(),
  received_at TIMESTAMPTZ,
  read_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (id, recipient_id),
  CONSTRAINT messages_message_type_check CHECK (message_type = ANY(ARRAY['user'::TEXT, 'system'::TEXT]))
);

COMMENT ON TABLE messages IS 'Encrypted messages with RLS enabled';
COMMENT ON COLUMN messages.id IS 'Message ID shared across all recipient copies of the same logical message';
COMMENT ON COLUMN messages.recipient_id IS 'User ID this encrypted message copy is for';
COMMENT ON COLUMN messages.encrypted_content IS 'RSA-encrypted message content for the recipient';
COMMENT ON COLUMN messages.received_at IS 'Timestamp when the recipient received/fetched the message from server';
COMMENT ON COLUMN messages.read_at IS 'Timestamp when the recipient read the message in the app';
COMMENT ON COLUMN messages.updated_at IS 'Timestamp of last update, automatically maintained by trigger';
COMMENT ON CONSTRAINT messages_pkey ON messages IS 'Composite primary key allowing same message ID for different recipients';

-- Create indexes for efficient message queries
CREATE INDEX idx_messages_recipient ON messages(chat_id, recipient_id, created_at DESC);
CREATE INDEX idx_messages_unread ON messages(recipient_id, read_at) WHERE read_at IS NULL;

-- ============================================================================
-- PART 6: Device Tokens Table
-- ============================================================================

CREATE TABLE device_tokens (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  token TEXT NOT NULL UNIQUE,
  platform TEXT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  CONSTRAINT device_tokens_platform_check CHECK (platform = ANY(ARRAY['android'::TEXT, 'ios'::TEXT, 'web'::TEXT]))
);

COMMENT ON TABLE device_tokens IS 'Stores FCM device tokens for push notifications';

-- Create indexes for device token queries
CREATE INDEX idx_device_tokens_user_id ON device_tokens(user_id);
CREATE INDEX idx_device_tokens_token ON device_tokens(token);

-- ============================================================================
-- PART 7: Realtime Publications
-- ============================================================================

-- Enable realtime for all tables
ALTER PUBLICATION supabase_realtime ADD TABLE profiles;
ALTER PUBLICATION supabase_realtime ADD TABLE chats;
ALTER PUBLICATION supabase_realtime ADD TABLE chat_members;
ALTER PUBLICATION supabase_realtime ADD TABLE pending_chat_members;
ALTER PUBLICATION supabase_realtime ADD TABLE messages;
