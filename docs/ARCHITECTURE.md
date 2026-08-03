# Chattr - Realtime Chat App Architektur

## 🧠 Grundprinzip

**Realtime-Listener gehören NIE direkt in Widgets**

Stattdessen:
```
Supabase Realtime
        ↓
   Repository
        ↓
 Riverpod Notifier
        ↓
      UI
```

➡️ **UI hört nur auf State**  
➡️ **Notifier kennt Business-Logik**  
➡️ **Repository spricht Supabase**

## 📁 Projektstruktur

```
lib/
 ├─ core/
 │   ├─ supabase/
 │   │   ├─ supabase_client_provider.dart
 │   │   └─ realtime_subscription.dart
 │
 ├─ features/
 │   ├─ auth/
 │   │   ├─ auth_controller.dart
 │   │   └─ auth_repository.dart
 │
 │   ├─ profiles/
 │   │   ├─ profile_model.dart
 │   │   ├─ profiles_repository.dart
 │   │   └─ profiles_controller.dart
 │
 │   ├─ chats/
 │   │   ├─ chat_model.dart
 │   │   ├─ chats_repository.dart
 │   │   └─ chats_controller.dart
 │
 │   ├─ messages/
 │   │   ├─ message_model.dart
 │   │   ├─ messages_repository.dart
 │   │   └─ messages_controller.dart
```

## 🔑 Features

- ✅ **Anonymous Supabase Auth**
- ✅ **Saubere Cleanup-Strategie**
- ✅ **Realtime für Messages, Chats & Profile**
- ✅ **Kein Provider-Spaghetti**
- ✅ **Leicht testbar & erweiterbar**

## 🧩 Warum diese Architektur stabil bleibt

| Problem | Lösung |
|---------|--------|
| Realtime-Leaks | `dispose()` im Controller |
| State-Chaos | Eine Quelle pro Feature |
| Rebuild-Hölle | Gezielte Provider |
| Testbarkeit | Repository mockbar |
| Skalierung | Neue Tables = gleiches Pattern |

## 🚀 Setup

1. **Flutter & Dependencies installieren:**
```bash
./setup_chattr.sh
```

2. **Supabase lokal starten:**
```bash
supabase start
```

3. **App initialisieren:**

In `lib/main.dart`:
```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: 'http://localhost:54321',
    anonKey: 'YOUR_ANON_KEY',
  );

  runApp(
    const ProviderScope(
      child: MyApp(),
    ),
  );
}
```

## 📊 Datenbank-Schema

Siehe `supabase/migrations/00001_initial_schema.sql`

## 💡 Usage im UI

```dart
// Messages für einen Chat anzeigen
final messages = ref.watch(messagesControllerProvider(chatId));

ListView.builder(
  itemCount: messages.length,
  itemBuilder: (_, i) => Text(messages[i].content),
);
```

➡️ **Kein StreamBuilder**  
➡️ **Kein Supabase-Code im Widget**  
➡️ **Kein Chaos**

## 🧹 Cleanup-Strategie

**Server-seitig via Scheduled Function oder Cron:**

```sql
delete from profiles
where id not in (
  select id from auth.users
);
```

➡️ **Client macht KEIN Cleanup**

## 🔐 QR-Code Flow

Jeder User hat eine UUID. QR-Code enthält:
```json
{
  "type": "chattr_user",
  "user_id": "UUID"
}
```

Siehe benötigte Libraries in `pubspec.yaml`:
- `qr_flutter` (erstellen)
- `mobile_scanner` (scannen)
