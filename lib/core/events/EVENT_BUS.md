# Central Event Bus System

## Overview
Instead of subscribing to multiple Supabase Realtime channels (one per chat, one for chat_members, etc.), we use a **single user-specific channel** that acts as a central event bus. All events for a user are routed through this channel.

## Architecture

### User-Specific Channel
- **Channel Name**: `user:{userId}`
- **Transport**: Supabase Realtime Broadcast
- **Lifecycle**: Created when user logs in, destroyed on logout

### Event Flow
```
Server/Client → Broadcast Event → User Channel → EventBusService → Handlers
```

## Event Types

### NewMessageEvent
Triggered when a new message is sent to a chat the user is a member of.
```dart
{
  "type": "newMessage",
  "user_id": "...",
  "chat_id": "...",
  "message_id": "...",
  "sender_id": "...",
  "content": "Hello!",
  "timestamp": "2024-01-09T..."
}
```

### NewChatEvent
Triggered when the user is added to a new chat.
```dart
{
  "type": "newChat",
  "user_id": "...",
  "chat_id": "...",
  "member_ids": ["...", "..."],
  "timestamp": "2024-01-09T..."
}
```

### ChatUpdateEvent
Triggered when chat metadata changes (e.g., name, avatar).
```dart
{
  "type": "chatUpdate",
  "user_id": "...",
  "chat_id": "...",
  "updates": { "name": "New Chat Name" },
  "timestamp": "2024-01-09T..."
}
```

### MessageUpdateEvent
Triggered when a message is edited.
```dart
{
  "type": "messageUpdate",
  "user_id": "...",
  "chat_id": "...",
  "message_id": "...",
  "updates": { "content": "Updated message" },
  "timestamp": "2024-01-09T..."
}
```

### MessageDeleteEvent
Triggered when a message is deleted.
```dart
{
  "type": "messageDelete",
  "user_id": "...",
  "chat_id": "...",
  "message_id": "...",
  "timestamp": "2024-01-09T..."
}
```

## Usage

### In Controllers
Controllers register event handlers on initialization:

```dart
// ChatsController
eventBus.on(EventType.newChat, (event) {
  if (event is NewChatEvent) {
    _handleNewChat(event);
  }
});

// MessagesController (with filtering)
eventBus.on(EventType.newMessage, (event) {
  if (event is NewMessageEvent && event.chatId == this.chatId) {
    _handleNewMessage(event);
  }
});
```

### Using Streams
For reactive listening:

```dart
// Listen to all events
eventBus.eventStream.listen((event) {
  print('Event: ${event.type}');
});

// Listen to specific event type
eventBus.eventStreamOf<NewMessageEvent>().listen((event) {
  print('New message in chat: ${event.chatId}');
});
```

### Sending Events (Testing/Local)
```dart
await eventBus.send(NewMessageEvent(
  userId: userId,
  chatId: chatId,
  messageId: messageId,
  senderId: senderId,
  content: content,
));
```

## Benefits

### 1. **Single Connection**
- Only one Supabase Realtime channel per user
- Reduced connection overhead
- Lower server load

### 2. **Scalability**
- Adding new event types doesn't require new subscriptions
- Easy to extend with new features
- Centralized event handling

### 3. **Filtering**
- Events are filtered in the client, not in subscriptions
- Controllers only handle relevant events
- Efficient event routing

### 4. **Debugging**
- All events visible in one stream
- Easy to log and monitor
- Simpler troubleshooting

## Server-Side Implementation

### Supabase Edge Function Example
When a message is created, broadcast to all chat members:

```typescript
// On message insert
supabase.from('messages')
  .on('INSERT', async (payload) => {
    const message = payload.new;
    
    // Get chat members
    const { data: members } = await supabase
      .from('chat_members')
      .select('user_id')
      .eq('chat_id', message.chat_id);
    
    // Broadcast to each member's channel
    for (const member of members) {
      await supabase.channel(`user:${member.user_id}`)
        .send({
          type: 'broadcast',
          event: 'event',
          payload: {
            type: 'newMessage',
            user_id: member.user_id,
            chat_id: message.chat_id,
            message_id: message.id,
            sender_id: message.sender_id,
            content: message.content,
            timestamp: message.created_at,
          },
        });
    }
  });
```

### Database Trigger Alternative
Use PostgreSQL triggers to broadcast events:

```sql
CREATE OR REPLACE FUNCTION broadcast_new_message()
RETURNS TRIGGER AS $$
DECLARE
  member_id TEXT;
BEGIN
  -- Loop through chat members
  FOR member_id IN 
    SELECT user_id FROM chat_members 
    WHERE chat_id = NEW.chat_id
  LOOP
    -- Broadcast to user's channel
    PERFORM pg_notify(
      'user:' || member_id,
      json_build_object(
        'type', 'newMessage',
        'user_id', member_id,
        'chat_id', NEW.chat_id,
        'message_id', NEW.id,
        'sender_id', NEW.sender_id,
        'content', NEW.content,
        'timestamp', NEW.created_at
      )::text
    );
  END LOOP;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER message_broadcast
AFTER INSERT ON messages
FOR EACH ROW
EXECUTE FUNCTION broadcast_new_message();
```

## Comparison: Old vs New

### Old Approach (Per-Table Subscriptions)
```dart
// ChatsController
channel = client.channel('realtime:chat_members');
channel.onPostgresChanges(...);

// MessagesController (per chat!)
channel = client.channel('realtime:messages');
channel.onPostgresChanges(...);
```

**Problems**:
- Multiple active channels per user
- One channel per open chat
- Complex subscription management
- Higher server load

### New Approach (Event Bus)
```dart
// Single channel for user
eventBus = EventBusService(client, userId);
await eventBus.subscribe();

// Controllers just register handlers
eventBus.on(EventType.newMessage, handleMessage);
eventBus.on(EventType.newChat, handleChat);
```

**Benefits**:
- Single channel per user
- Centralized event routing
- Easier to manage
- Scales better

## Future Enhancements
- [ ] Event prioritization
- [ ] Event batching for performance
- [ ] Offline event queue
- [ ] Event replay on reconnect
- [ ] Analytics/monitoring integration
