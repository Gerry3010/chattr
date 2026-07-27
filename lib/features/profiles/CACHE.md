# Profile Cache System

## 🎯 Konzept

Der ProfilesController verwaltet einen intelligenten Cache für User-Profile:
- **Vermeidet redundante API-Calls**
- **Lädt Profile nur einmal**
- **Batch-Loading für mehrere Profile**
- **Automatische Updates via Realtime**

## 📦 Cache-Struktur

```dart
State: Map<String, Profile>
// userId -> Profile

{
  "user-abc-123": Profile(id: "...", username: "Max"),
  "user-def-456": Profile(id: "...", username: "Anna"),
}
```

## 🔧 Methoden

### loadProfile(userId)
Lädt ein einzelnes Profil (nur wenn noch nicht im Cache)
```dart
await ref.read(profilesControllerProvider.notifier).loadProfile('user-123');
```

### loadProfiles(userIds)
**Effizientes Batch-Loading** für mehrere Profile
```dart
await ref.read(profilesControllerProvider.notifier).loadProfiles([
  'user-1', 'user-2', 'user-3'
]);
```

### getCachedProfile(userId)
Holt Profil aus Cache (oder null)
```dart
final profile = ref.read(profilesControllerProvider.notifier)
  .getCachedProfile('user-123');
```

### isProfileCached(userId)
Prüft ob Profil im Cache ist
```dart
final isCached = ref.read(profilesControllerProvider.notifier)
  .isProfileCached('user-123');
```

### refreshProfile(userId)
Forciert Neu-Laden (ignoriert Cache)
```dart
await ref.read(profilesControllerProvider.notifier).refreshProfile('user-123');
```

### clearCache()
Leert den kompletten Cache
```dart
ref.read(profilesControllerProvider.notifier).clearCache();
```

## 🚀 Helper Provider

### profileProvider
Einfacher Zugriff auf einzelnes Profil (lädt automatisch)
```dart
final profile = ref.watch(profileProvider('user-123'));
if (profile != null) {
  Text(profile.username);
}
```

### profilesListProvider
Mehrere Profile gleichzeitig (batch loading)
```dart
final profiles = ref.watch(profilesListProvider(['user-1', 'user-2']));
```

### usernameProvider
Nur Username (mit Fallback)
```dart
final username = ref.watch(usernameProvider('user-123')); 
// → "Max" oder "Loading..."
```

## 💡 Usage Beispiele

### In Chat-Liste: Usernames anzeigen
```dart
class ChatListItem extends ConsumerWidget {
  final Chat chat;
  
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Hole Member IDs
    final memberIds = chat.memberIds;
    
    // Automatisches Laden + Caching
    final profiles = ref.watch(profilesListProvider(memberIds));
    
    return ListTile(
      title: Text(profiles.map((p) => p.username).join(', ')),
    );
  }
}
```

### In Message-Bubble: Sender anzeigen
```dart
final senderName = ref.watch(usernameProvider(message.senderId));
Text(senderName); // Automatisch gecached!
```

## ⚡ Performance-Vorteile

| Ohne Cache | Mit Cache |
|------------|-----------|
| API-Call bei jedem Widget rebuild | Nur 1x laden |
| Langsam (Network) | Sofort (Memory) |
| Redundante Requests | Batch-Loading |
| Hohe Datennutzung | Minimal |

## 🔄 Realtime Updates

Profile werden automatisch aktualisiert wenn:
- Neues Profil erstellt wird (onInsert)
- Profil geändert wird (onUpdate)
- Profil gelöscht wird (onDelete)

**Kein manuelles Refresh nötig!**

## 🧹 Cache Management

Cache wird geleert bei:
- `clearCache()` manuell aufgerufen
- Controller disposed (automatisch)
- Logout (empfohlen)

```dart
// Bei Logout Cache leeren
ref.read(profilesControllerProvider.notifier).clearCache();
await ref.read(authControllerProvider.notifier).logout();
```
