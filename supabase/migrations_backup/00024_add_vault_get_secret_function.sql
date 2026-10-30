-- Create private schema and get_secret function for Vault access
-- This function allows database functions to securely access secrets from vault.decrypted_secrets

-- Create private schema (not exposed in API)
CREATE SCHEMA IF NOT EXISTS private;

COMMENT ON SCHEMA private IS 'Schema for internal functions not exposed via PostgREST API';

-- Create function to retrieve secrets from Vault
CREATE OR REPLACE FUNCTION private.get_secret(secret_name TEXT)
RETURNS TEXT
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
   secret TEXT;
BEGIN
   SELECT decrypted_secret INTO secret 
   FROM vault.decrypted_secrets 
   WHERE name = secret_name;
   
   RETURN secret;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION private.get_secret IS 'Retrieves a decrypted secret from vault.decrypted_secrets by name. Used by database functions to access sensitive configuration like service_role_key.';

-- Grant execute permission to postgres and service_role
GRANT EXECUTE ON FUNCTION private.get_secret(TEXT) TO postgres, service_role;