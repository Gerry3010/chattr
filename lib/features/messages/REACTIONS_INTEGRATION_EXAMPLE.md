# Message Reactions Integration Example

## Quick Start

So integrierst du Message Reactions in deinen ChatView:

### 1. Import der benötigten Dateien

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:chatview/chatview.dart' as chatview;
import 'chat_view_reactions_adapter.dart';
```

### 2. In deinem ChatView Widget

```dart
class ChatScreen extends ConsumerWidget {
  final String chatId;
  
  const ChatScreen({required this.chatId, super.key});
  
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return chatview.ChatView(
      // ... andere Properties ...
      
      // 🎯 WICHTIG: ReactionPopupConfiguration hinzufügen
      reactionPopupConfig: buildReactionPopupConfiguration(ref, chatId),
      
      // Optional: Emoji-Configuration
      emojiConfig: buildEmojiConfiguration(ref, chatId),
      
      // ... andere Properties ...
    );
  }
}
```

### 3. Reactions unter Nachrichten anzeigen

Um Reactions unter jeder Nachricht anzuzeigen, verwende das `MessageReactionDisplay` Widget:

```dart
// In deiner Custom Message Bubble oder Builder
Widget buildMessageWithReactions(String messageId) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      // Deine normale Message Bubble
      MessageBubble(messageId: messageId),
      
      // Reactions Display darunter
      MessageReactionDisplay(messageId: messageId),
    ],
  );
}
```

### 4. Vollständiges Beispiel

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:chatview/chatview.dart' as chatview;
import 'chat_view_reactions_adapter.dart';
import 'message_reactions_controller.dart';

class MyChatScreen extends ConsumerStatefulWidget {
  final String chatId;
  
  const MyChatScreen({required this.chatId, super.key});
  
  @override
  ConsumerState<MyChatScreen> createState() => _MyChatScreenState();
}

class _MyChatScreenState extends ConsumerState<MyChatScreen> {
  late chatview.ChatController _chatController;
  
  @override
  void initState() {
    super.initState();
    _chatController = chatview.ChatController(
      initialMessageList: [], // Deine Messages
      scrollController: ScrollController(),
      chatUsers: [], // Deine Chat-User
    );
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: chatview.ChatView(
        chatController: _chatController,
        currentUser: chatview.ChatUser(id: 'current-user-id'),
        
        // 🎯 Reactions Configuration
        reactionPopupConfig: buildReactionPopupConfiguration(
          ref, 
          widget.chatId,
        ),
        
        // Emoji Configuration
        emojiConfig: buildEmojiConfiguration(ref, widget.chatId),
        
        // Custom Message Builder (optional)
        messageConfig: chatview.MessageConfiguration(
          customMessageBuilder: (message) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Standard Message
                chatview.MessageView(
                  message: message,
                  isMessageBySender: message.sendBy == 'current-user-id',
                ),
                
                // Reactions unter der Message
                MessageReactionDisplay(messageId: message.id),
              ],
            );
          },
        ),
      ),
    );
  }
  
  @override
  void dispose() {
    _chatController.dispose();
    super.dispose();
  }
}
```

## Features

### ✅ Was funktioniert automatisch:
- Long-Press auf Message öffnet Reaction Picker
- Tap auf Emoji fügt Reaction hinzu
- Nochmal Tap entfernt die eigene Reaction
- Realtime Updates wenn andere User reagieren
- Anzeige wer reagiert hat (Tap auf Reaction)

### 🎨 Anpassungen

#### Custom Styling
```dart
chatview.ReactionPopupConfiguration(
  userReactionCallback: adapter.onReactionCallback,
  showGlassMorphismEffect: true,
  backgroundColor: Colors.grey[900],
  maxWidth: 300,
  padding: EdgeInsets.all(16),
  margin: EdgeInsets.symmetric(horizontal: 20),
  animationDuration: Duration(milliseconds: 250),
)
```

#### Nur bestimmte Emojis erlauben
```dart
emojiConfig: chatview.EmojiConfiguration(
  emojiPickerView: chatview.DefaultEmojiPickerView(
    emojiPickerConfig: chatview.EmojiPickerConfig(
      emojiViewConfig: chatview.EmojiViewConfig(
        columns: 7,
        emojiSizeMax: 32,
        // Nur diese Kategorien anzeigen
        categoryEmoji: CategoryEmoji(
          // Definiere hier deine Custom Emoji-Liste
        ),
      ),
    ),
  ),
)
```

## Troubleshooting

### Problem: Reactions werden nicht gespeichert
**Lösung:** Stelle sicher, dass die Migration gelaufen ist:
```bash
cd supabase
sudo supabase migration up
```

### Problem: Realtime Updates funktionieren nicht
**Lösung:** Prüfe, ob Supabase Realtime aktiviert ist:
```sql
ALTER PUBLICATION supabase_realtime ADD TABLE message_reactions;
```

### Problem: User sieht keine Reactions
**Lösung:** Stelle sicher, dass der User Mitglied des Chats ist (RLS Policy).

## Next Steps

1. ✅ Migration deployen: `supabase migration up`
2. ✅ Dependencies installieren: `flutter pub get`
3. ✅ Freezed generieren: `dart run build_runner build`
4. ✅ Integration in ChatView (siehe Beispiel oben)
5. 🚀 Testen!

## API Reference

### buildReactionPopupConfiguration()
Erstellt die komplette ReactionPopupConfiguration mit Backend-Integration.

**Parameters:**
- `ref: WidgetRef` - Riverpod Ref für State Management
- `chatId: String` - ID des aktuellen Chats

**Returns:** `chatview.ReactionPopupConfiguration`

### buildEmojiConfiguration()
Erstellt die EmojiConfiguration für den Emoji-Picker.

**Parameters:**
- `ref: WidgetRef` - Riverpod Ref
- `chatId: String` - Chat ID

**Returns:** `chatview.EmojiConfiguration`

### MessageReactionDisplay Widget
Zeigt Reactions für eine Nachricht an.

**Properties:**
- `messageId: String` (required) - ID der Nachricht
- `onTap: VoidCallback?` (optional) - Callback bei Tap

## Support

Bei Fragen oder Problemen, siehe:
- `message_reactions_controller.dart` - State Management
- `message_reactions_repository.dart` - Backend-Integration
- `chatview_reactions_adapter.dart` - ChatView Adapter
