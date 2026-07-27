drop function new_system_message (uuid, text, text);

create or replace function new_system_message (
  p_chat_id UUID,
  p_content TEXT,
  p_action TEXT default null
) RETURNS TEXT[] SECURITY DEFINER LANGUAGE plpgsql as $$
DECLARE
  result TEXT[] := '{}';
  -- v_message messages;
  member_record RECORD;
  message_id UUID;
  encrypted_content TEXT;
  pub_key TEXT;
BEGIN
  -- Generate a single message ID for all recipient copies
  message_id := gen_random_uuid();
  
  -- For each accepted member, encrypt the message with their public key
  FOR member_record IN
    SELECT user_id, public_key
    FROM chat_members
    WHERE chat_id = p_chat_id
      AND accepted = true
      AND public_key IS NOT NULL
  LOOP
    -- Encrypt message content with member's public key using pgcrypto
    -- Convert encrypted bytes to base64 for storage
    BEGIN
      -- result := result || dearmor(member_record.public_key);
      -- pub_key := regexp_replace(member_record.public_key, E'[\\n\\r]+', '', 'g' );
      -- result := result || pub_key;
      encrypted_content := encode(
        pgp_pub_encrypt(
          p_content,
          dearmor(member_record.public_key),
          'cipher-algo=aes256'
        ),
        'base64'
      );
      -- result := result || encrypted_content;
    EXCEPTION WHEN OTHERS THEN
      -- If encryption fails, log and skip this member
      -- RAISE warning 'Failed to encrypt system message for user %: %', member_record.user_id, SQLERRM;
      RAISE exception 'Failed to encrypt system message for user %: %', member_record.user_id, SQLERRM;
      CONTINUE;
    END;
    
    -- Insert message row for this recipient
    INSERT INTO messages (
      id,
      chat_id,
      sender_id,
      recipient_id,
      encrypted_content,
      message_type,
      created_at
    ) VALUES (
      message_id,
      p_chat_id,
      NULL,  -- System messages have no sender
      member_record.user_id,
      encrypted_content,
      'system',
      NOW()
    );
    --returning * into v_message;
    --result := result || member_record.public_key;
  END LOOP;

  RETURN result;
END;
$$;

select
  new_system_message (
    'af530c94-c6f2-41fe-9de7-360ef7e8d729',
    'joined the chat',
    'joined'
  );

--DO $$
--BEGIN
--SELECT new_system_message('af530c94-c6f2-41fe-9de7-360ef7e8d729', 'joined the chat', 'joined');
--END $$ language plpgsql;