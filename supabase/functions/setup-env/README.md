# Environment Setup Function

This Edge Function loads environment variables into the Supabase Vault so they can be accessed by database functions.

## Purpose

Database functions (triggers, RPC functions) need access to certain environment variables like:
- Edge Function URLs
- Service Role Key (for calling other functions)

Since these can't be accessed directly from SQL, we store them in:
1. **Supabase Vault** - via `vault.get_secret()`
2. **PostgreSQL Runtime Settings** - via `current_setting()`

## Usage

### Local Development

After starting Supabase locally:

```bash
# From the supabase directory
./setup-env.sh
```

Or manually:

```bash
curl -X POST http://kong:8000/functions/v1/setup-env \
  -H "Authorization: Bearer YOUR_SERVICE_ROLE_KEY" \
  -H "Content-Type: application/json"
```

### Production Deployment

The function should be called automatically after deployment. You can also trigger it manually via:

```bash
curl -X POST https://your-project.supabase.co/functions/v1/setup-env \
  -H "Authorization: Bearer YOUR_SERVICE_ROLE_KEY" \
  -H "Content-Type: application/json"
```

## Environment Variables Stored

The function currently stores:

- `edge_function_url` - Base URL for Edge Functions
- `service_role_key` - Service role key for authenticated function calls

## Accessing Variables in SQL

```sql
-- Edge Function URL (non-sensitive, via runtime settings)
SELECT current_setting('app.settings.edge_function_url', true);

-- Service Role Key (sensitive, via Vault only)
SELECT private.get_secret('service_role_key');
```

**Security Note:** The service role key is only accessible via `private.get_secret()` which reads from `vault.decrypted_secrets`. It is NOT stored in `app.settings` for security reasons.

## Adding New Variables

To add more environment variables, edit `setup-env/index.ts` and add them to the `secrets` array:

```typescript
const secrets: VaultSecret[] = [
  // ... existing secrets
  {
    name: "your_var_name",
    value: Deno.env.get("YOUR_ENV_VAR") ?? "",
  },
];
```

## Security Note

This function requires the Service Role Key and should only be called:
- During deployment/startup
- By authorized administrators
- Never from client-side code
