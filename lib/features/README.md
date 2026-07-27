# Features

## 🎯 Konzept

**Features enthalten die Business-Logik und State Management.**

Screens (UI) befinden sich in `lib/screens/` und nutzen diese Features.

## 📁 Struktur

Jedes Feature folgt diesem Pattern:

```
feature_name/
├── feature_name.dart              # Barrel export
├── feature_name_controller.dart   # Riverpod StateNotifier
├── feature_name_repository.dart   # Daten-Zugriff (Supabase)
├── feature_name_model.dart        # Datenmodelle
└── widgets/                       # Feature-spezifische Widgets
    └── *.dart
```

## 🔧 Verfügbare Features

### 1. Auth (`features/auth/`)
- **Zweck**: Anonyme Authentication
- **Controller**: `AuthController`
- **Repository**: `AuthRepository`
- **Widgets**: `AuthStateHandler` (Routing)

### 2. Chats (`features/chats/`)
- **Zweck**: Chat Management
- **Controller**: `ChatsController` (mit Realtime)
- **Repository**: `ChatsRepository`
- **Models**: `Chat`

### 3. Messages (`features/messages/`)
- **Zweck**: Nachrichten mit Realtime-Updates
- **Controller**: `MessagesController` (mit Realtime)
- **Repository**: `MessagesRepository`
- **Models**: `Message`

### 4. Profiles (`features/profiles/`)
- **Zweck**: User-Profile Management
- **Controller**: `ProfilesController` (mit Realtime)
- **Repository**: `ProfilesRepository`
- **Models**: `Profile`

## 🔄 Realtime-Architektur

Features mit Realtime folgen diesem Pattern:

```dart
class FeatureController extends StateNotifier<State> {
  final Ref ref;
  final Repository repo;
  RealtimeChannel? _channel;

  FeatureController(this.ref, this.repo, ...) : super(initialState) {
    _init();
  }

  Future<void> _init() async {
    // 1. Initial data laden
    state = await repo.fetchInitial();

    // 2. Realtime listener setup
    _channel = RealtimeSubscription(
      client: ref.read(supabaseClientProvider),
      table: 'table_name',
      onInsert: (payload) {
        // State updaten
      },
    ).subscribe();
  }

  @override
  void dispose() {
    _channel?.unsubscribe(); // Cleanup!
    super.dispose();
  }
}
```

## 📦 Usage in Screens

```dart
import '../../features/auth/auth.dart';
import '../../features/chats/chats.dart';

class MyScreen extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Feature State abrufen
    final userId = ref.watch(authControllerProvider);
    final chats = ref.watch(chatsControllerProvider);
    
    // Feature Actions aufrufen
    ref.read(authControllerProvider.notifier).login();
    
    return Scaffold(...);
  }
}
```

## ➕ Neues Feature hinzufügen

1. **Ordner erstellen**: `lib/features/new_feature/`
2. **Dateien erstellen**:
   - `new_feature_model.dart`
   - `new_feature_repository.dart`
   - `new_feature_controller.dart`
   - `new_feature.dart` (barrel export)
3. **Controller mit Riverpod**: `StateNotifier` oder `StateNotifierProvider`
4. **Optional**: Realtime-Updates hinzufügen
5. **In Screens nutzen**: Import aus `features/new_feature/`

## 🧪 Testing

Features sind unabhängig von UI und können isoliert getestet werden:

```dart
test('AuthController login', () async {
  final mockRepo = MockAuthRepository();
  final controller = AuthController(mockRepo);
  
  await controller.login();
  
  expect(controller.state, isNotNull);
});
```
