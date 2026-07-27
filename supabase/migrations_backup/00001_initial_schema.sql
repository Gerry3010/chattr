-- users (kein Email Login!)
create table profiles (
  id uuid primary key default gen_random_uuid(),
  username text not null,
  created_at timestamptz default now()
);

-- chats
create table chats (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz default now()
);

-- chat members
create table chat_members (
  chat_id uuid references chats(id) on delete cascade,
  user_id uuid references profiles(id) on delete cascade,
  primary key (chat_id, user_id)
);

-- messages
create table messages (
  id uuid primary key default gen_random_uuid(),
  chat_id uuid not null references chats(id) on delete cascade,
  sender_id uuid references profiles(id),
  content text,
  created_at timestamptz default now()
);

-- Realtime aktivieren
alter publication supabase_realtime add table messages;
alter publication supabase_realtime add table chats;
alter publication supabase_realtime add table chat_members;
alter publication supabase_realtime add table profiles;
