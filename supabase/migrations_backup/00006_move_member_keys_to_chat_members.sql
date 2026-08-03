-- Migration: Move member public keys from chats.member_keys to chat_members.public_key
-- This normalizes the data structure and makes key management per-member instead of per-chat

-- 1. Add public_key column to chat_members
ALTER TABLE chat_members 
ADD COLUMN public_key TEXT DEFAULT NULL;

COMMENT ON COLUMN chat_members.public_key IS 'RSA public key (PEM format) for this user in this chat';

-- 2. Create index for faster lookups
CREATE INDEX IF NOT EXISTS idx_chat_members_public_key ON chat_members(chat_id, user_id) WHERE public_key IS NOT NULL;

-- 3. Drop trigger and function that depend on member_keys
DROP TRIGGER IF EXISTS chat_key_exchange_trigger ON chats;
DROP FUNCTION IF EXISTS broadcast_key_exchange();

-- 4. Drop the policy that references member_keys
DROP POLICY IF EXISTS "Members can update chat member_keys" ON chats;

-- 5. Migrate existing data from chats.member_keys to chat_members.public_key
-- This migration assumes member_keys is in format: {user_id: public_key_pem}
-- Note: This is a one-time migration script
DO $$
DECLARE
  chat_record RECORD;
  key_record RECORD;
BEGIN
  FOR chat_record IN SELECT id, member_keys FROM chats WHERE member_keys IS NOT NULL AND jsonb_typeof(member_keys) = 'object'
  LOOP
    -- Iterate over each key-value pair in member_keys JSONB
    FOR key_record IN 
      SELECT key::uuid as user_id, value as public_key
      FROM jsonb_each_text(chat_record.member_keys)
    LOOP
      -- Update chat_members with public key
      UPDATE chat_members 
      SET public_key = key_record.public_key
      WHERE chat_id = chat_record.id AND user_id = key_record.user_id;
    END LOOP;
  END LOOP;
END $$;

-- 6. Drop the member_keys column from chats
ALTER TABLE chats DROP COLUMN IF EXISTS member_keys;

COMMENT ON COLUMN chat_members.public_key IS 'RSA public key (PEM format) for this member in this chat';
