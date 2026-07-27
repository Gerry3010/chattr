DROP FUNCTION new_system_message(uuid,text,text); 

CREATE OR REPLACE FUNCTION new_system_message(
  p_chat_id UUID,
  p_content TEXT,
  p_action TEXT DEFAULT NULL
)
RETURNS TEXT
SECURITY DEFINER
AS $$
DECLARE
  function_url TEXT;
  response TEXT;
BEGIN
  
  -- Get Edge Function URL
  function_url := COALESCE(
    current_setting('app.settings.edge_function_url', true),
    --'http://localhost:54321/functions/v1/insert-system-message'
    'http://kong:8000/functions/v1/insert-system-message'
  );
  
  -- Call Edge Function to encrypt and insert message
  BEGIN
    SELECT
    "content"::jsonb
    INTO response
    FROM
    extensions.http((
      'POST',
      function_url,
      ARRAY[extensions.http_header('Authorization', 'Bearer ' || current_setting('app.settings.service_role_key', true))],
      'application/json',
      jsonb_build_object(
        'chat_id', p_chat_id::text,
        'content', p_content,
        'action', p_action
      )::text
    )
    );
    return response;
  EXCEPTION WHEN OTHERS THEN
    -- Log error but don't fail the trigger
    RAISE exception 'Failed to call insert-system-message Edge Function: %', SQLERRM;
  END;
END;
$$ LANGUAGE plpgsql;

select new_system_message(
  'f8e6da29-167c-4b22-816b-6eacbea0d9f4',
    'Test',
    'Left'
  );