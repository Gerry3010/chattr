# Push Notifications Setup - TODO

## 1. Database Migration ausführen

```bash
cd /home/gerry/Sync-Projekte/Chattr2/chattr

# Option A: Supabase neu starten (empfohlen)
supabase start

# Option B: Database reset (löscht alle Daten!)
# supabase db reset
```

## 2. Firebase Credentials holen

### 2.1 Service Account Key generieren
1. Gehe zu [Firebase Console](https://console.firebase.google.com/)
2. Wähle dein Projekt aus
3. Gehe zu **Project Settings** (⚙️ oben links) → **Service Accounts**
4. Klicke auf **"Generate new private key"**
5. Bestätige mit **"Generate key"**
6. Eine JSON-Datei wird heruntergeladen

### 2.2 Credentials aus JSON extrahieren
Öffne die heruntergeladene JSON-Datei und finde:
- `private_key` - Das ist dein FCM_SERVER_KEY
- `project_id` - Das ist dein FCM_PROJECT_ID

**Beispiel JSON-Struktur:**
```json
{
  "type": "service_account",
  "project_id": "dein-projekt-id",
  "private_key_id": "...",
  "private_key": "-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----\n",
  ...
}
```

## 3. Supabase Secrets konfigurieren

```bash
cd /home/gerry/Sync-Projekte/Chattr2/chattr

# Setze FCM Server Key (kompletter private_key aus JSON)
supabase secrets set FCM_SERVER_KEY="-----BEGIN PRIVATE KEY-----
dein-kompletter-private-key-hier
-----END PRIVATE KEY-----"

# Setze Firebase Project ID
supabase secrets set FCM_PROJECT_ID="dein-projekt-id"
```

**Wichtig:**
- Der `FCM_SERVER_KEY` muss den kompletten private key inklusive `-----BEGIN PRIVATE KEY-----` und `-----END PRIVATE KEY-----` enthalten
- Achte auf korrekte Quotes (verwende `"` nicht `'`)
- Bei Newlines (`\n`) im Key: entweder wörtlich übernehmen oder als String mit escaped newlines

## 4. Edge Function deployen

```bash
cd /home/gerry/Sync-Projekte/Chattr2/chattr

# Function deployen
supabase functions deploy send-push-notification

# Überprüfen ob deployed
supabase functions list
```

## 5. Testen (Optional)

### 5.1 Test-Token manuell in DB einfügen
```sql
-- Ersetze USER_ID und TEST_TOKEN mit echten Werten
INSERT INTO device_tokens (user_id, token, platform)
VALUES ('deine-user-id', 'test-fcm-token', 'android');
```

### 5.2 Edge Function testen
```bash
curl -X POST 'http://kong:8000/functions/v1/send-push-notification' \
  -H "Authorization: Bearer YOUR_ANON_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "new_message",
    "user_ids": ["deine-user-id"],
    "title": "Test Notification",
    "body": "This is a test!",
    "data": {
      "chat_id": "test-chat-id"
    }
  }'
```

## 6. Web-Support

✅ Web-Support ist bereits implementiert!

**Was funktioniert:**
- Browser-Notifications via Service Worker
- Foreground und Background Notifications
- Notification Click Handling
- Chrome, Firefox, Edge, Safari 16+ Support

**Testen:**
1. Starte Web-Version: `flutter run -d chrome`
2. Erlaube Notifications wenn gefragt
3. FCM Token wird im Log angezeigt

**Einschränkungen:**
- iOS Safari: Limited Support (nur mit "Add to Home Screen")
- Private Mode: Keine Notifications
- Browser muss offen sein (Tab kann minimiert sein)

## 7. App-Integration (Phase 4)

✅ App-Integration ist abgeschlossen!

**Was implementiert wurde:**
- [x] FCM Service in app_init.dart initialisieren
- [x] Token Registration bei Login (auth_controller.dart)
- [x] Token Deletion bei Logout (auth_controller.dart)
- [ ] Notification Navigation Handler (TODO: Implement in FCMService._processNotificationData)

**Wie es funktioniert:**
1. App startet → FCM initialisiert → Token generiert
2. User loggt ein → Token wird in Supabase gespeichert
3. User loggt aus → Token wird aus Supabase gelöscht
4. Token refresh → Automatisch in Supabase aktualisiert

## Häufige Probleme

### "FCM credentials not configured"
➡️ Stelle sicher, dass die Secrets korrekt gesetzt sind:
```bash
supabase secrets list
```

### "permission denied" bei Docker
➡️ User zu docker Gruppe hinzufügen:
```bash
sudo usermod -aG docker $USER
# Dann neu einloggen
```

### Migration schlägt fehl
➡️ Prüfe ob Supabase läuft:
```bash
supabase status
```

### FCM Token ist null
➡️ Permissions wurden nicht erteilt oder Firebase ist nicht initialisiert

## Nächste Schritte

Nach Abschluss dieser Schritte:
1. Melde dich bei mir zurück
2. Wir implementieren Phase 4 (App-Integration)
3. Testen mit echtem Device
