# Push delivery debugging (iOS/Android) — server-side checklist

Status as of 2026-07-07: notifications don't arrive on the physical iPhone, even
though the **client side is fully verified correct** (Mac/iOS scope). The break is
in the server chain **DB trigger → `send-push-notification` edge function → FCM → APNs**.

This doc is the cross-machine hand-off (Mac-Claude → Linux/backend). It captures a
ranked diagnosis so the backend work is targeted, not guesswork.

---

## ⚡ VERIFIED ROOT CAUSE — 2026-07-07 (Linux/backend, from live prod logs)

**The backend chain is 100% correct. The break is an iOS APNs environment
mismatch — Apple/build scope, NOT backend.** Do NOT re-investigate candidates
1–3 below; they were all checked against prod and are fine:

- `FCM_SERVICE_ACCOUNT` → **present** in the edge runtime (2331 B), OAuth token
  is minted successfully (no "OAuth token exchange failed" in logs).
- `app.settings.edge_function_url` → NULL, but the `kong:8000` fallback **works
  on this self-hosted stack** (db + kong share the docker network); the function
  is reached. Not the bug. (Nice-to-have: still set it via `setup-env` so the
  config is explicit — but it does not block delivery.)
- `device_tokens` → has the iOS test token (ios×1, web×3). Fine.
- The edge function runs, finds the token, authenticates to FCM, FCM forwards to
  APNs — and **APNs rejects it**:

```json
"error": { "code": 401, "status": "UNAUTHENTICATED",
  "details": [
    { "@type": "…FcmError",  "errorCode": "THIRD_PARTY_AUTH_ERROR" },
    { "@type": "…ApnsError", "statusCode": 403, "reason": "BadEnvironmentKeyInToken" }
  ] }
```

`BadEnvironmentKeyInToken` = the device's APNs token belongs to a **different
APNs environment (sandbox vs production)** than the one FCM delivered to. The
iPhone is running a **Debug/Profile build** → `Runner.entitlements` →
`aps-environment: development` → a **sandbox** token; FCM delivers to
**production** APNs → mismatch → 403.

### 🍎 Fix (Mac-Claude scope)

1. **Primary path — test push from a TestFlight (Release) build.** Release signs
   with `RunnerRelease.entitlements` (`aps-environment: production`) → production
   APNs token → matches FCM. A Debug/Profile build installed on the device will
   *always* fail push with `BadEnvironmentKeyInToken`. Since TestFlight is the
   plan anyway, this is the real-world fix — just verify push on the TestFlight
   build, not the Xcode/dev build.
2. **If dev-build push testing is also wanted:** with
   `FirebaseAppDelegateProxyEnabled=false`, ensure the APNs token is forwarded to
   Firebase with the **sandbox** type under DEBUG — i.e.
   `Messaging.messaging().setAPNSToken(deviceToken, type: .sandbox)` (or `.unknown`
   to auto-detect) in `didRegisterForRemoteNotificationsWithDeviceToken`. Gate by
   `#if DEBUG` → `.sandbox`, else `.prod`.

**Backend is done. No edge-function / migration / secret change is needed for
this.** Everything below is the original (now-superseded) server-side ranking,
kept for history.

---

## ✅ Verified correct — do NOT re-investigate the client

- FCM token is obtained on device (`FCMService.initialize`: `FCM Token obtained: …`).
- Notification permission requested; foreground/background/tap handlers wired;
  `setForegroundNotificationPresentationOptions(alert/badge/sound)`; local
  notifications initialized (`lib/features/push_notifications/fcm_service.dart`).
- iOS push entitlement signed: `aps-environment` present in the codesigned binary +
  embedded provisioning profile (Team `ND9MT2PP6B`, App ID `net.geraldhofbauer.chattr`).
- APNs `.p8` auth key uploaded to Firebase project `your-firebase-project`.
- Edge-function FCM **payload shape** is correct (`notification.title/body` +
  `apns.payload.aps.sound` + `android.notification.channel_id`), asserted by
  `supabase/functions/tests/push_notification_test.ts`. → iOS *would* display it.

## ✅ Already addressed by commit `8d731be`

- Edge functions are rsynced into the served `volumes/functions` and the service is
  restarted on deploy (future edits actually deploy).
- Vault seeded (idempotent) with `service_role_key` + `project_url` used by the
  notify triggers.

## 🔧 Open candidates — ranked (hosted Supabase: `api.chattr.geraldhofbauer.net`)

### 1. `FCM_SERVICE_ACCOUNT` secret (top suspect)
The edge function mints an OAuth2 token for the **FCM HTTP v1 API** from a Firebase
**service-account JSON** — this is a *different credential* from the APNs `.p8`:
- `.p8` → lets Firebase/FCM deliver to Apple's APNs (already uploaded).
- `FCM_SERVICE_ACCOUNT` → lets *our edge function* authenticate to FCM at all.

If missing, the function throws `FCM_SERVICE_ACCOUNT secret not configured`
(`supabase/functions/send-push-notification/index.ts:48-64`). Set it:
```
supabase secrets set FCM_SERVICE_ACCOUNT="$(cat service-account.json)"
```
Get the JSON: Firebase Console → Project settings → Service accounts → Generate new
private key. (See `supabase/functions/send-push-notification/README.md`.)

### 2. `app.settings.edge_function_url` actually set on hosted
The message trigger (`supabase/migrations/00003_event_functions.sql:97-100`, also
`00002`, `00024`) reads `current_setting('app.settings.edge_function_url', true)` and
**falls back to `http://kong:8000/functions/v1/…`** — the local docker gateway, which
does not resolve on hosted → `net.http_post` silently fails. It is set by the
`setup-env` edge function (`supabase/functions/setup-env/index.ts:105-114`). Verify:
```sql
SELECT current_setting('app.settings.edge_function_url', true);
```
Should return the hosted functions base (e.g. `https://api.chattr.geraldhofbauer.net/functions/v1`),
not null and not `kong:8000`. If null/wrong, run `setup-env` or set it directly.

### 3. `device_tokens` has rows for the test user
Client registers the token after login (`registerToken` →
`device_tokens.upsert`). If empty, the function logs
`No device tokens found for users: …` (`index.ts:277`) and returns without sending.
Check: `SELECT user_id, platform, left(token,12) FROM device_tokens;`

### 4. Read the actual error
Supabase Dashboard → Edge Functions → `send-push-notification` → Logs, and the
`net` (pg_net) response table for the trigger's HTTP POST. The real failure is in
one of those two logs — iterate from there.

## Definition of done
Send a message from a second account to the iPhone (app backgrounded) → a banner
appears. **No iOS/client changes are needed** — this is purely backend/infra.
