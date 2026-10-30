# Message Pagination

## Overview
Messages are loaded with pagination to improve performance for large chats. By default, only the most recent 50 messages are loaded initially.

## Usage

### In UI (ChatScreen)
To implement "load more" functionality in your chat UI:

```dart
// Get controller
final controller = ref.read(messagesControllerProvider(chatId).notifier);

// Check if more messages are available
final hasMore = controller.hasMore;
final isLoading = controller.isLoadingMore;

// Load more messages (e.g., when user scrolls to top)
if (hasMore && !isLoading) {
  await controller.loadMore();
}
```

### Example Implementation with ScrollController

```dart
class ChatScreen extends ConsumerStatefulWidget {
  final String chatId;
  const ChatScreen({required this.chatId});
  
  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final ScrollController _scrollController = ScrollController();
  
  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }
  
  void _onScroll() {
    // Check if scrolled near top (for loading older messages)
    if (_scrollController.position.pixels < 100) {
      final controller = ref.read(
        messagesControllerProvider(widget.chatId).notifier
      );
      
      if (controller.hasMore && !controller.isLoadingMore) {
        controller.loadMore();
      }
    }
  }
  
  @override
  Widget build(BuildContext context) {
    final messages = ref.watch(messagesControllerProvider(widget.chatId));
    final controller = ref.read(
      messagesControllerProvider(widget.chatId).notifier
    );
    
    return ListView.builder(
      controller: _scrollController,
      reverse: true, // Start at bottom (most recent)
      itemCount: messages.length + (controller.hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        // Show loading indicator at top
        if (index == messages.length) {
          return controller.isLoadingMore
            ? CircularProgressIndicator()
            : TextButton(
                onPressed: () => controller.loadMore(),
                child: Text('Load More'),
              );
        }
        
        final message = messages[messages.length - 1 - index];
        return MessageWidget(message: message);
      },
    );
  }
  
  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }
}
```

## Configuration

### Page Size
Default page size is 50 messages. To change:
```dart
// In MessagesController
static const int _pageSize = 100; // Change to desired size
```

### Load All Messages
For special cases (e.g., export, search), use:
```dart
final allMessages = await localRepo.loadAllMessages(chatId);
```
⚠️ Warning: This loads ALL messages and may be slow for large chats.

## Performance Notes
- Initial load: 50 messages (fast)
- Each "load more": 50 additional messages
- Messages are decrypted on-demand
- Uses indexed queries for optimal performance
- Chronological order maintained (oldest to newest in list)

## Database Queries
The pagination uses efficient SQL queries:
```sql
-- Initial load: Get 50 most recent
SELECT * FROM messages 
WHERE chat_id = ? 
ORDER BY created_at DESC 
LIMIT 50

-- Load more: Get 50 older than oldest loaded
SELECT * FROM messages 
WHERE chat_id = ? AND created_at < ? 
ORDER BY created_at DESC 
LIMIT 50
```

## Future Enhancements
- [ ] Bidirectional pagination (load newer messages too)
- [ ] Virtual scrolling for very long chats
- [ ] Message search across all messages
- [ ] Jump to date functionality
