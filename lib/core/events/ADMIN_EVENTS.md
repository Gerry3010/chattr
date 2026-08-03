# Admin Management Events

## Overview
New event types for the central event bus to handle member and admin management in real-time.

## New Event Types

### 1. MemberAddedEvent
Fired when a new member is added to a chat.

**Fields:**
- `chatId` (String): The chat ID
- `addedUserId` (String): User ID of the newly added member
- `addedByUserId` (String): User ID who added the member (admin)
- `userId` (String): Recipient of this event
- `timestamp` (DateTime): Event timestamp

**Usage:**
```dart
eventBus.on(EventType.memberAdded, (event) {
  if (event is MemberAddedEvent && event.chatId == currentChatId) {
    // Refresh member list
    ref.invalidate(chatMembersProvider(event.chatId));
    
    // Show notification
    showSnackbar('${event.addedUserId} was added to the chat');
  }
});
```

### 2. MemberRemovedEvent
Fired when a member is removed from a chat (by admin) or leaves voluntarily.

**Fields:**
- `chatId` (String): The chat ID
- `removedUserId` (String): User ID of the removed member
- `removedByUserId` (String): User ID who removed the member (could be self)
- `userId` (String): Recipient of this event
- `timestamp` (DateTime): Event timestamp

**Usage:**
```dart
eventBus.on(EventType.memberRemoved, (event) {
  if (event is MemberRemovedEvent) {
    // If current user was removed, navigate away
    if (event.removedUserId == currentUserId) {
      Navigator.pop(context);
      showSnackbar('You were removed from the chat');
    } else {
      // Refresh member list
      ref.invalidate(chatMembersProvider(event.chatId));
    }
  }
});
```

### 3. AdminPromotedEvent
Fired when a user is promoted to admin status.

**Fields:**
- `chatId` (String): The chat ID
- `promotedUserId` (String): User ID who was promoted
- `promotedByUserId` (String): User ID who performed the promotion
- `userId` (String): Recipient of this event
- `timestamp` (DateTime): Event timestamp

**Usage:**
```dart
eventBus.on(EventType.adminPromoted, (event) {
  if (event is AdminPromotedEvent && event.chatId == currentChatId) {
    // Invalidate admin status cache
    ref.invalidate(isAdminProvider((chatId: event.chatId, userId: event.promotedUserId)));
    
    // Reload chat to get updated admins array
    ref.invalidate(chatsControllerProvider);
    
    // Show notification
    if (event.promotedUserId == currentUserId) {
      showSnackbar('You are now an admin!');
    }
  }
});
```

### 4. AdminDemotedEvent
Fired when a user is demoted from admin status.

**Fields:**
- `chatId` (String): The chat ID
- `demotedUserId` (String): User ID who was demoted
- `demotedByUserId` (String): User ID who performed the demotion
- `userId` (String): Recipient of this event
- `timestamp` (DateTime): Event timestamp

**Usage:**
```dart
eventBus.on(EventType.adminDemoted, (event) {
  if (event is AdminDemotedEvent && event.chatId == currentChatId) {
    // Invalidate admin status cache
    ref.invalidate(isAdminProvider((chatId: event.chatId, userId: event.demotedUserId)));
    
    // Reload chat to get updated admins array
    ref.invalidate(chatsControllerProvider);
    
    // Show notification
    if (event.demotedUserId == currentUserId) {
      showSnackbar('You are no longer an admin');
    }
  }
});
```

### 5. ChatDeletedEvent
Fired when a chat is deleted by an admin.

**Fields:**
- `chatId` (String): The chat ID that was deleted
- `deletedByUserId` (String): User ID who deleted the chat (admin)
- `userId` (String): Recipient of this event
- `timestamp` (DateTime): Event timestamp

**Usage:**
```dart
eventBus.on(EventType.chatDeleted, (event) {
  if (event is ChatDeletedEvent) {
    // Remove chat from local storage
    await chatsLocalRepo.deleteChat(event.chatId);
    
    // Navigate away if user is viewing this chat
    if (currentChatId == event.chatId) {
      Navigator.popUntil(context, (route) => route.isFirst);
      showSnackbar('This chat was deleted');
    }
    
    // Refresh chat list
    ref.invalidate(chatsControllerProvider);
  }
});
```

## Server-Side Event Broadcasting

These events should be broadcast from Supabase triggers or Edge Functions when the corresponding actions occur.

### Example Trigger for Member Addition
```sql
CREATE OR REPLACE FUNCTION broadcast_member_added()
RETURNS TRIGGER AS $$
DECLARE
  member_record RECORD;
BEGIN
  -- Notify all chat members
  FOR member_record IN 
    SELECT user_id FROM chat_members 
    WHERE chat_id = NEW.chat_id
  LOOP
    PERFORM pg_notify(
      'user:' || member_record.user_id,
      json_build_object(
        'type', 'memberAdded',
        'user_id', member_record.user_id,
        'chat_id', NEW.chat_id,
        'added_user_id', NEW.user_id,
        'added_by_user_id', auth.uid(),
        'timestamp', NOW()
      )::text
    );
  END LOOP;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER chat_member_added_trigger
AFTER INSERT ON chat_members
FOR EACH ROW
EXECUTE FUNCTION broadcast_member_added();
```

### Example Trigger for Admin Promotion
```sql
CREATE OR REPLACE FUNCTION broadcast_admin_changes()
RETURNS TRIGGER AS $$
DECLARE
  member_record RECORD;
  added_admins UUID[];
  removed_admins UUID[];
BEGIN
  -- Calculate differences in admins array
  added_admins := ARRAY(SELECT unnest(NEW.admins) EXCEPT SELECT unnest(OLD.admins));
  removed_admins := ARRAY(SELECT unnest(OLD.admins) EXCEPT SELECT unnest(NEW.admins));
  
  -- Notify all chat members
  FOR member_record IN 
    SELECT user_id FROM chat_members 
    WHERE chat_id = NEW.id
  LOOP
    -- Broadcast promotions
    IF array_length(added_admins, 1) > 0 THEN
      PERFORM pg_notify(
        'user:' || member_record.user_id,
        json_build_object(
          'type', 'adminPromoted',
          'user_id', member_record.user_id,
          'chat_id', NEW.id,
          'promoted_user_id', added_admins[1],
          'promoted_by_user_id', auth.uid(),
          'timestamp', NOW()
        )::text
      );
    END IF;
    
    -- Broadcast demotions
    IF array_length(removed_admins, 1) > 0 THEN
      PERFORM pg_notify(
        'user:' || member_record.user_id,
        json_build_object(
          'type', 'adminDemoted',
          'user_id', member_record.user_id,
          'chat_id', NEW.id,
          'demoted_user_id', removed_admins[1],
          'demoted_by_user_id', auth.uid(),
          'timestamp', NOW()
        )::text
      );
    END IF;
  END LOOP;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER chat_admins_changed_trigger
AFTER UPDATE OF admins ON chats
FOR EACH ROW
WHEN (OLD.admins IS DISTINCT FROM NEW.admins)
EXECUTE FUNCTION broadcast_admin_changes();
```

## Database Schema Updates

### Version 2 Migration
The local database schema version has been updated to 2. No actual schema changes are needed because:

1. Admin fields (`created_by`, `admins`) are stored as part of the encrypted JSON in the `encrypted_data` BLOB
2. The encryption/decryption layer handles serialization of the new fields
3. Existing data remains compatible

**Migration Logic:**
```dart
if (oldVersion < 2) {
  // No actual schema changes needed - data is stored as encrypted JSON
  // which already supports new fields
}
```

## Implementation Checklist

- [x] Add new event types to EventType enum
- [x] Create event classes with fromJson/toJson
- [x] Update BusEvent.fromJson() factory to handle new types
- [x] Update database schema version to 2
- [x] Add migration logic (no-op for encrypted JSON storage)
- [ ] Create Supabase triggers for event broadcasting
- [ ] Update ChatsController to handle new events
- [ ] Update UI to show admin badges and actions
- [ ] Test event flow end-to-end

## Notes

- All events are sent through the user-specific Realtime channel: `user:{userId}`
- Events are only received by authenticated users who are members of the affected chat
- RLS policies ensure only authorized users can trigger these events
- Local storage automatically handles the new fields through JSON serialization
