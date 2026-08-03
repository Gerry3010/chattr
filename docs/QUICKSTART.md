# Chattr - Quick Start

## ✅ Setup abgeschlossen!

Alle Libraries sind eingerichtet und initialisiert:
- ✅ **Supabase** - Verbunden mit lokalem Backend
- ✅ **Riverpod** - State Management
- ✅ **Flutter Hooks** - Reactive UI
- ✅ **Secure Storage** - Verfügbar
- ✅ **QR Code** - Scanner & Generator Libraries
- ✅ **Chat UI** - chatview Package

## 🚀 App starten

### 1. Supabase starten
```bash
sudo supabase start
```

**Wichtige URLs:**
- Studio: http://127.0.0.1:54323
- API: http://127.0.0.1:54321

### 2. Flutter App starten
```bash
flutter run
```

## 📁 Projektstruktur

```
lib/
├── app.dart                    # Main App Widget
├── main.dart                   # Entry Point
├── core/
│   ├── config/
│   │   └── supabase_config.dart    # Supabase URLs & Keys
│   ├── init/
│   │   └── app_init.dart           # App Initialisierung
│   └── supabase/
│       ├── supabase_client_provider.dart
│       └── realtime_subscription.dart
└── features/
    ├── auth/                   # Anonyme Authentication
    ├── chats/                  # Chat Management
    ├── messages/               # Message Handling + Realtime
    └── profiles/               # User Profiles
```

## 🔧 Konfiguration

Die Supabase-Verbindung ist in `lib/core/config/supabase_config.dart` konfiguriert:

```dart
static const String supabaseUrl = 'http://127.0.0.1:54321';
static const String supabaseAnonKey = 'sb_publishable_...';
```

## 💡 Nächste Schritte

1. **UI Screens erstellen** für:
   - Login/Onboarding
   - Chat Liste
   - Chat Detail
   - QR Code Scanner/Generator

2. **Authentication Flow** implementieren:
   ```dart
   // Anonyme Anmeldung
   ref.read(authControllerProvider.notifier).login();
   ```

3. **Realtime Messages** nutzen:
   ```dart
   final messages = ref.watch(messagesControllerProvider(chatId));
   ```

4. **QR Code Features** bauen für User hinzufügen

## 📚 Wichtige Packages

- `hooks_riverpod` - State Management mit Hooks
- `supabase_flutter` - Backend & Realtime
- `flutter_secure_storage` - Sichere Datenspeicherung
- `qr_flutter` - QR Code erstellen
- `mobile_scanner` - QR Code scannen
- `chatview` - Chat UI Komponenten

## 🔍 Testing

```bash
# Analyze
flutter analyze

# Test
flutter test

# Supabase Status
sudo supabase status
```

## 📖 Weitere Dokumentation

- `ARCHITECTURE.md` - Detaillierte Architektur-Erklärung
- `README.md` - Projekt-Übersicht
