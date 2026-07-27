# Push Notifications Implementation Plan

## Problem Statement
Currently, Chattr only has in-app notifications that are displayed when the app is open. Users need real push notifications (even when the app is closed/backgrounded) for:
- New messages in chats
- Member join requests (for admins)
- Member request accepted/rejected

## Current State
- ✅ In-app notification system exists (`InAppNotificationService`)
- ✅ Supabase database triggers for events (`notify_admins_pending_member`, `notify_members_new_message`)
- ✅ Event bus system for in-app communication
- ❌ No Firebase setup
- ❌ No device token management
- ❌ No push notification sending mechanism

## Proposed Solution
Implement Firebase Cloud Messaging (FCM) with Supabase Edge Functions to send push notifications.

### Architecture Overview
1. **Client (Flutter)**:
   - Register for FCM and get device token
   - Store token in Supabase
   - Handle notifications in foreground/background/terminated states
   - Update token on changes/app launch

2. **Supabase Database**:
   - New table: `device_tokens` to store user FCM tokens
   - Triggers call Edge Functions on events

3. **Supabase Edge Function**:
   - Receives event data from triggers
   - Queries relevant device tokens
   - Sends FCM notifications via HTTP API

## Implementation Steps

### Phase 1: Client Setup (Flutter)

#### 1.1 Add Dependencies
Add to `pubspec.yaml`:
- `firebase_core`: Firebase initialization
- `firebase_messaging`: FCM functionality
- `flutter_local_notifications`: Local notification display (for foreground)

#### 1.2 Firebase Project Setup
- Create Firebase project in Firebase Console
- Add Android app (package: `com.chattr.app`)
- Add iOS app (bundle: `com.chattr.app`)
- Download `google-services.json` (Android) and `GoogleService-Info.plist` (iOS)
- Place config files in correct locations

#### 1.3 Platform Configuration
**Android** (`android/app/build.gradle.kts`):
- Add Firebase dependencies
- Configure multidex if needed

**iOS** (`ios/Runner/Info.plist`):
- Add notification permissions
- Configure background modes

#### 1.4 FCM Service Implementation
Create `lib/features/push_notifications/fcm_service.dart`:
- Initialize Firebase
- Request notification permissions
- Get FCM token
- Listen to token refresh
- Handle foreground/background/terminated notifications
- Navigate to chat on notification tap

#### 1.5 Token Management
Create `lib/features/push_notifications/device_token_repository.dart`:
- Save token to Supabase on login
- Update token on refresh
- Delete token on logout
- Handle multiple devices per user

#### 1.6 Notification Handler
Create `lib/features/push_notifications/notification_handler.dart`:
- Parse notification payload
- Show local notification in foreground
- Handle navigation based on notification type
- Update badge counts

### Phase 2: Database Setup

#### 2.1 Device Tokens Table
Create migration `supabase/migrations/XXXXX_create_device_tokens.sql`:
```sql
CREATE TABLE device_tokens (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  token TEXT NOT NULL UNIQUE,
  platform TEXT NOT NULL CHECK (platform IN ('android', 'ios', 'web')),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_device_tokens_user_id ON device_tokens(user_id);
CREATE INDEX idx_device_tokens_token ON device_tokens(token);

-- RLS policies
ALTER TABLE device_tokens ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can manage own tokens"
  ON device_tokens
  FOR ALL
  USING (auth.uid() = user_id);
```

#### 2.2 Update Existing Triggers
Modify triggers to call Edge Function:
- `notify_admins_pending_member`: Call push function with admin IDs
- `notify_members_new_message`: Call push function with chat member IDs

### Phase 3: Edge Function Setup

#### 3.1 Create Edge Function
Create `supabase/functions/send-push-notification/index.ts`:
- Accept notification payload (type, user_ids, title, body, data)
- Query device tokens for target users
- Format FCM payload
- Send via FCM HTTP v1 API
- Handle errors and retry logic
- Log delivery status

#### 3.2 FCM Server Key Setup
- Generate service account key in Firebase Console
- Store credentials in Supabase secrets
- Use OAuth2 for FCM HTTP v1 API authentication

#### 3.3 Notification Payloads
Define payload structures for each notification type:

**New Message**:
```json
{
  "type": "new_message",
  "chat_id": "uuid",
  "chat_name": "string",
  "sender_name": "string",
  "message_preview": "string"
}
```

**Member Request** (for admins):
```json
{
  "type": "member_request",
  "chat_id": "uuid",
  "chat_name": "string",
  "requester_name": "string",
  "requester_id": "uuid"
}
```

**Request Accepted/Rejected**:
```json
{
  "type": "request_accepted" | "request_rejected",
  "chat_id": "uuid",
  "chat_name": "string"
}
```

### Phase 4: Integration & Testing

#### 4.1 App Initialization
Update `lib/core/init/app_init.dart`:
- Initialize Firebase
- Initialize FCM service
- Register device token on login

#### 4.2 Auth Integration
Update `lib/features/auth/auth_controller.dart`:
- Register token after successful login
- Delete token on logout

#### 4.3 Testing Checklist
- [ ] Token registration on login
- [ ] Token update on refresh
- [ ] Token deletion on logout
- [ ] Notification received in foreground
- [ ] Notification received in background
- [ ] Notification received when app terminated
- [ ] Tap navigation works correctly
- [ ] Multiple devices per user
- [ ] Android notifications
- [ ] iOS notifications
- [ ] Notification permissions handling

### Phase 5: Advanced Features (Optional)

#### 5.1 Notification Preferences
Allow users to configure:
- Enable/disable notifications per chat
- Mute chats for X hours
- Notification sound selection
- Vibration patterns

#### 5.2 Smart Notifications
- Don't send push if user is already viewing the chat
- Batch notifications ("3 new messages in Chat X")
- Priority notifications for mentions

#### 5.3 Analytics
- Track notification delivery rates
- Monitor FCM token failures
- Log user engagement with notifications

## Security Considerations
1. **Token Security**: Device tokens are sensitive - ensure RLS policies are correct
2. **Payload Encryption**: Don't send full message content in push (only preview)
3. **Rate Limiting**: Prevent notification spam via Edge Function rate limits
4. **User Privacy**: Respect mute/DND settings
5. **Token Cleanup**: Remove stale tokens (failed deliveries, old devices)

## Performance Considerations
1. **Batch Sends**: Send to multiple tokens in single FCM request (up to 500)
2. **Async Processing**: Edge Function should process tokens asynchronously
3. **Token Caching**: Cache active tokens in Edge Function for performance
4. **Retry Logic**: Implement exponential backoff for failed deliveries

## Migration Strategy
1. Deploy database changes (device_tokens table)
2. Deploy Edge Function
3. Release app update with FCM support
4. Monitor token registration rate
5. Gradually enable push notifications for all users
6. Keep in-app notifications as fallback

## Dependencies
- Firebase project setup (free tier sufficient)
- Supabase Edge Functions (included in plan)
- Firebase Admin SDK credentials

## Estimated Effort
- Phase 1 (Client): ~8 hours
- Phase 2 (Database): ~2 hours
- Phase 3 (Edge Function): ~6 hours
- Phase 4 (Integration & Testing): ~6 hours
- **Total: ~22 hours**

## Resources
- [Firebase Cloud Messaging Docs](https://firebase.google.com/docs/cloud-messaging)
- [flutter_local_notifications](https://pub.dev/packages/flutter_local_notifications)
- [Supabase Edge Functions](https://supabase.com/docs/guides/functions)
- [FCM HTTP v1 API](https://firebase.google.com/docs/cloud-messaging/migrate-v1)
