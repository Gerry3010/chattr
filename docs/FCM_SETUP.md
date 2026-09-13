# FCM Setup - Environment Variables

## Lokale Entwicklung

Um Push Notifications lokal zu testen, musst du die folgenden Umgebungsvariablen setzen:

### 1. Private Key extrahieren

Der Private Key befindet sich in `fcm-private-key.json`. Du musst den kompletten Wert (inklusive `<DEIN_PRIVATE_KEY_AUS_DER_SERVICE_ACCOUNT_JSON>`) extrahieren.

```bash
# Private Key aus JSON extrahieren
FCM_SERVER_KEY=$(jq -r '.private_key' fcm-private-key.json)

# Oder manuell: Öffne fcm-private-key.json und kopiere den "private_key" Wert
```

### 2. Project ID extrahieren

```bash
# Project ID aus JSON extrahieren
FCM_PROJECT_ID=$(jq -r '.project_id' fcm-private-key.json)

# Oder manuell: Der Wert ist "your-firebase-project"
```

### 3. Umgebungsvariablen für Supabase setzen

**Option A: In deiner Shell-Konfiguration (~/.zshrc)**

```bash
export FCM_PROJECT_ID="your-firebase-project"
export FCM_SERVER_KEY="<DEIN_PRIVATE_KEY_AUS_DER_SERVICE_ACCOUNT_JSON>"
```

**Option B: Temporär in der aktuellen Shell-Session**

```bash
export FCM_PROJECT_ID="your-firebase-project"
export FCM_SERVER_KEY=$(jq -r '.private_key' fcm-private-key.json)
```

**Option C: In einer .env Datei (für supabase CLI)**

Erstelle eine `.env` Datei im Projekt-Root:

```bash
FCM_PROJECT_ID=your-firebase-project
FCM_SERVER_KEY="<DEIN_PRIVATE_KEY_AUS_DER_SERVICE_ACCOUNT_JSON>"
```

Dann lade sie vor dem Starten von Supabase:

```bash
set -a; source .env; set +a
sudo -E supabase start
```

### 4. Supabase neu starten

Nach dem Setzen der Umgebungsvariablen musst du Supabase mit den Environment Variables neu starten:

```bash
# Mit sudo und Beibehaltung der Environment Variables
sudo -E supabase stop
sudo -E supabase start
```

Das `-E` Flag sorgt dafür, dass sudo die Umgebungsvariablen übernimmt.

## Produktion (Supabase Cloud)

Für Production musst du die Secrets über die Supabase CLI oder das Dashboard setzen:

### Via CLI (nach Login)

```bash
supabase login
supabase link --project-ref YOUR_PROJECT_REF

# Secrets setzen
supabase secrets set FCM_PROJECT_ID=your-firebase-project
supabase secrets set FCM_SERVER_KEY="$(jq -r '.private_key' fcm-private-key.json)"

# Edge Function deployen
supabase functions deploy send-push-notification
```

### Via Supabase Dashboard

1. Gehe zu deinem Projekt: https://supabase.com/dashboard/project/YOUR_PROJECT_ID
2. Navigiere zu **Settings → Edge Functions → Manage secrets**
3. Füge hinzu:
   - `FCM_PROJECT_ID`: `your-firebase-project`
   - `FCM_SERVER_KEY`: [vollständiger Private Key aus fcm-private-key.json]
4. Deploye die Edge Function über CLI oder Dashboard

## Testen

Nach dem Setup kannst du die Push Notifications testen:

1. Starte die App auf einem Gerät/Emulator
2. Melde dich an (registriert automatisch das Device Token)
3. Sende eine Nachricht von einem anderen User
4. Du solltest eine Push Notification erhalten

### Logs prüfen

```bash
# Edge Function Logs
sudo supabase functions logs send-push-notification

# Oder im Supabase Studio
# http://127.0.0.1:54323 → Edge Functions → send-push-notification → Logs
```
