# Send Push Notification Edge Function

This Supabase Edge Function sends Firebase Cloud Messaging (FCM) push notifications to specified users.

## Authentication

This function uses the **FCM HTTP v1 API**, which authenticates with a
short-lived OAuth2 access token minted from a Firebase **service account** — not
a static "server key". (Google removed the legacy `/fcm/send` API and its server
keys in June 2024.) The function builds and RS256-signs a JWT with the service
account's private key, exchanges it at `https://oauth2.googleapis.com/token` for
a `firebase.messaging`-scoped access token, and caches it until ~1 min before it
expires.

The function itself is **service-role gated**: it must be called server-to-server
with the Supabase service-role key (the DB trigger does this). A normal anon/user
JWT is rejected with 401, so the public anon key cannot be used to spam pushes.

## Setup

### 1. Get the Firebase service account

1. Firebase Console → Project Settings → Service Accounts
2. Click "Generate new private key" → downloads a JSON file
3. That JSON (with `client_email`, `private_key`, `project_id`) is the credential

### 2. Configure Supabase secrets

```bash
# Paste the FULL service-account JSON (single value).
supabase secrets set FCM_SERVICE_ACCOUNT="$(cat path/to/service-account.json)"

# Optional — defaults to project_id inside the service account.
supabase secrets set FCM_PROJECT_ID="your-firebase-project-id"
```

For local dev, put the JSON on one line **wrapped in single quotes** in
`supabase/functions/.env` (see `.env.example`) — single quotes stop the dotenv
parser from stripping the JSON's double-quotes:

```
FCM_SERVICE_ACCOUNT='{"type":"service_account",...}'
```

### 3. Deploy Function

```bash
supabase functions deploy send-push-notification
```

## Usage

### Request Format

```typescript
{
  "type": "new_message" | "member_request" | "request_accepted" | "request_rejected",
  "user_ids": ["uuid1", "uuid2"],
  "title": "Notification Title",
  "body": "Notification Body",
  "data": {
    "chat_id": "uuid",
    "additional": "data"
  }
}
```

### Example: New Message Notification

```bash
curl -X POST 'https://your-project.supabase.co/functions/v1/send-push-notification' \
  -H "Authorization: Bearer YOUR_SERVICE_ROLE_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "new_message",
    "user_ids": ["user-uuid-1", "user-uuid-2"],
    "title": "New message in Chat",
    "body": "John: Hello!",
    "data": {
      "chat_id": "chat-uuid",
      "sender_name": "John"
    }
  }'
```

### Response Format

```typescript
{
  "success": true,
  "sent": 2,
  "failed": 0,
  "total": 2
}
```

## Integration with Database Triggers

Call this function from your database triggers:

```sql
-- Example: Call from message insert trigger
CREATE OR REPLACE FUNCTION notify_new_message()
RETURNS TRIGGER AS $$
DECLARE
  user_ids UUID[];
  chat_name TEXT;
  sender_name TEXT;
BEGIN
  -- Get chat members (excluding sender)
  SELECT ARRAY_AGG(user_id) INTO user_ids
  FROM chat_members
  WHERE chat_id = NEW.chat_id 
    AND user_id != NEW.sender_id
    AND accepted = true;

  -- Call edge function
  PERFORM
    net.http_post(
      url := 'https://your-project.supabase.co/functions/v1/send-push-notification',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || current_setting('app.settings.service_role_key')
      ),
      body := jsonb_build_object(
        'type', 'new_message',
        'user_ids', user_ids,
        'title', chat_name,
        'body', sender_name || ': ' || NEW.decrypted_content,
        'data', jsonb_build_object(
          'chat_id', NEW.chat_id::text,
          'sender_name', sender_name
        )
      )
    );

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
```

## Error Handling

- Returns 200 even if no tokens found (sent: 0)
- Logs failed token deliveries for cleanup
- Returns 400 for invalid requests
- Uses Promise.allSettled to handle partial failures

## Notes

- Requires `device_tokens` table to exist
- `FCM_SERVICE_ACCOUNT` must be configured as a Supabase secret
- Uses FCM HTTP v1 API with OAuth2 service-account auth (the legacy API is gone)
- Prunes tokens Google reports as `UNREGISTERED`/`INVALID_ARGUMENT` (or 404) from
  `device_tokens`, so dead tokens don't accumulate (`pruned` count in the response)
- Supports Android, iOS and Web (web push via the VAPID key in the Flutter client)
