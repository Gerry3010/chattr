# Screen-Struktur

## 🏗️ Architektur-Prinzip

**Screens sind von Features getrennt!**

Screens können mehrere Features kombinieren und befinden sich daher auf einer höheren Ebene:

```
lib/
├── screens/           # UI Screens (kombinieren Features)
│   ├── auth/
│   │   └── login_screen.dart
│   └── chat/
│       └── chat_list_screen.dart
│
├── features/          # Business Logik & State
│   ├── auth/          # Controller, Repository
│   ├── chats/         # Controller, Repository, Models
│   ├── messages/
│   └── profiles/
│
└── core/              # Shared Infrastructure
    ├── config/
    ├── init/
    └── supabase/
```

## 💡 Warum diese Trennung?

1. **Wiederverwendbarkeit**: Screens können mehrere Features nutzen
2. **Klare Verantwortlichkeiten**: Features = Logik, Screens = UI
3. **Einfachere Navigation**: Alle Screens an einem Ort
4. **Bessere Testbarkeit**: Features unabhängig von UI testbar

## Screens

### 1. AuthStateHandler
**Datei:** `features/auth/widgets/auth_state_handler.dart`

**Zweck:** Zentrale Routing-Logik basierend auf Authentication-Status

**Logik:**
- Wenn `userId == null` → `LoginScreen`
- Wenn `userId != null` → `ChatListScreen`

**Verwendung:** Wird in `app.dart` als `home` verwendet

---

### 2. LoginScreen
**Datei:** `features/auth/screens/login_screen.dart`

**Features:**
- ✅ Username TextField
- ✅ Anonymous Auth Button
- ✅ Loading State
- ✅ Error Handling
- ✅ Material3 Design

**Flow:**
1. User gibt Username ein
2. Klick auf "Anonym anmelden"
3. Anonymous Auth via Supabase
4. TODO: Profil mit Username erstellen
5. Automatischer Wechsel zu ChatListScreen (via AuthStateHandler)

**State Management:**
- `useState` für Loading State (flutter_hooks)
- `useTextEditingController` für TextField (flutter_hooks)
- `authControllerProvider` für Auth Actions (Riverpod)

---

### 3. ChatListScreen
**Datei:** `features/chats/screens/chat_list_screen.dart`

**Features:**
- ✅ AppBar mit Actions (QR Scanner, QR Code, Logout)
- ✅ Empty State mit Hinweis
- ✅ Chat-Liste mit Formatierung
- ✅ FloatingActionButton für neue Chats
- ✅ Datum-Formatierung (Heute/Gestern/vor X Tagen)

**State Management:**
- `chatsControllerProvider` (Riverpod)
- Automatische Updates via Realtime

**TODO-Items:**
- QR Scanner Navigation
- QR Code anzeigen
- Chat Detail Navigation

---

## Navigation-Flow

```
App Start
    ↓
AuthStateHandler
    ↓
    ├─→ (userId == null) → LoginScreen
    │                           ↓
    │                       Login Success
    │                           ↓
    └─→ (userId != null) → ChatListScreen
                              ↓
                          [TODOs]
                          ├─→ QR Scanner
                          ├─→ QR Code anzeigen
                          └─→ Chat Detail
```

## Ordnerstruktur-Konventionen

Jedes Feature folgt dieser Struktur:

```
feature_name/
├── feature_name.dart          # Barrel export
├── feature_name_controller.dart
├── feature_name_repository.dart
├── feature_name_model.dart
├── screens/
│   └── *.dart                 # Full-page Screens
└── widgets/
    └── *.dart                 # Reusable Widgets
```

## Hinzufügen neuer Screens

1. **Screen erstellen:**
   ```dart
   // features/feature_name/screens/new_screen.dart
   class NewScreen extends ConsumerWidget {
     const NewScreen({super.key});
     
     @override
     Widget build(BuildContext context, WidgetRef ref) {
       return Scaffold(...);
     }
   }
   ```

2. **In Barrel Export hinzufügen:**
   ```dart
   // features/feature_name/feature_name.dart
   export 'screens/new_screen.dart';
   ```

3. **Navigation implementieren:**
   ```dart
   Navigator.of(context).push(
     MaterialPageRoute(builder: (_) => const NewScreen()),
   );
   ```
