-- Enable Row Level Security on remaining tables
-- RLS policies for these tables already exist in previous migrations

-- Enable RLS on chats table
ALTER TABLE chats ENABLE ROW LEVEL SECURITY;

-- Enable RLS on messages table
ALTER TABLE messages ENABLE ROW LEVEL SECURITY;

-- Enable RLS on profiles table
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE chats IS 'Chat rooms with RLS enabled';
COMMENT ON TABLE messages IS 'Encrypted messages with RLS enabled';
COMMENT ON TABLE profiles IS 'User profiles with RLS enabled';
