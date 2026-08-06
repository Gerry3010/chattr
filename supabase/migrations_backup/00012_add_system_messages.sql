-- Add message_type column to messages table
-- Types: 'user' (default, encrypted user message) or 'system' (unencrypted system message)
alter table messages
add column message_type text not null default 'user' check (message_type in ('user', 'system'));

-- For system messages, sender_id is optional (can be null for system events)
alter table messages
alter column sender_id drop not null;

-- System messages don't have recipients or encryption (stored in content directly)
-- We keep encrypted_content for backward compatibility but it will be null for system messages
