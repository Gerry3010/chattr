# Chat Admin Features

## Overview
This document describes the admin and member management features for Chattr.

## Database Schema

### Chats Table
- `id` (UUID): Primary key
- `created_at` (timestamptz): Creation timestamp
- `created_by` (UUID): User who created the chat
- `admins` (UUID[]): Array of admin user IDs
- `member_keys` (JSONB): Map of userId -> RSA public keys for E2E encryption

### Chat Members Table
- `chat_id` (UUID): Reference to chats table
- `user_id` (UUID): Reference to profiles table
- Primary key: (chat_id, user_id)

## Admin Features

### Automatic Admin Assignment
- When a chat is created, the creator is automatically set as the first admin
- Trigger: `chat_creator_admin_trigger` calls `set_creator_as_admin()`

### Admin Reassignment on Leave
- When an admin leaves and no other admins remain, a random member is promoted to admin
- Trigger: `chat_member_leave_trigger` calls `reassign_admin_on_leave()`

## Permissions (RLS Policies)

### Chats
- **CREATE**: Any authenticated user can create a chat
- **DELETE**: Only admins can delete the chat
- **UPDATE**: Admins can update chat properties (including member_keys and admins array)

### Chat Members
- **SELECT**: Members can view other members of their chats
- **INSERT**: Only admins can add new members
- **DELETE**: Admins can remove members OR users can remove themselves

### Messages
- **SELECT**: Users can read their encrypted message copies (recipient_id = auth.uid())
- **INSERT**: Users can send messages to chat members
- **UPDATE**: Only senders can update their messages
- **DELETE**: Only recipients can delete their message copy

### Profiles
- **SELECT**: All authenticated users can view profiles
- **INSERT/UPDATE/DELETE**: Users can only manage their own profile

## Client-Side Usage

### Check Admin Status
```dart
// Using provider
final isAdmin = ref.watch(isAdminProvider((
  chatId: 'chat-id',
  userId: 'user-id',
)));

// Using Chat model
final chat = ref.watch(chatsControllerProvider).firstWhere((c) => c.id == chatId);
final isAdmin = chat.isAdmin('user-id');
```

### Member Management
```dart
final controller = ref.read(chatMembersControllerProvider);

// Add member (admin only)
await controller.addMember(
  chatId: 'chat-id',
  userId: 'user-id-to-add',
);

// Remove member (admin only or self)
await controller.removeMember(
  chatId: 'chat-id',
  userId: 'user-id-to-remove',
);

// Leave chat
await controller.leaveChat(
  chatId: 'chat-id',
  currentUserId: 'my-user-id',
);
```

### Admin Management
```dart
final controller = ref.read(chatMembersControllerProvider);

// Promote to admin (admin only)
await controller.promoteToAdmin(
  chatId: 'chat-id',
  userId: 'user-id-to-promote',
);

// Demote from admin (admin only, requires at least 2 admins)
await controller.demoteFromAdmin(
  chatId: 'chat-id',
  userId: 'user-id-to-demote',
);
```

### Get Chat Members
```dart
// Using provider
final members = ref.watch(chatMembersProvider('chat-id'));

members.when(
  data: (memberIds) => Text('Members: ${memberIds.length}'),
  loading: () => CircularProgressIndicator(),
  error: (err, stack) => Text('Error: $err'),
);

// Using repository directly
final repo = ref.read(chatMembersRepositoryProvider);
final memberIds = await repo.getChatMembers('chat-id');
```

### Delete Chat
```dart
final repo = ref.read(chatsRepositoryProvider);

// Only admins can delete chats (enforced by RLS)
await repo.deleteChat('chat-id');
```

## UI Considerations

### Show Admin Badge
```dart
if (chat.isAdmin(currentUserId)) {
  // Show admin badge or special UI
}
```

### Conditional Actions
```dart
// Show "Add Member" button only to admins
if (chat.isAdmin(currentUserId)) {
  ElevatedButton(
    onPressed: () => _showAddMemberDialog(),
    child: Text('Add Member'),
  );
}

// Show "Leave" button to all members
ElevatedButton(
  onPressed: () => controller.leaveChat(
    chatId: chat.id,
    currentUserId: currentUserId,
  ),
  child: Text('Leave Chat'),
);

// Show "Remove" button to admins (for other users)
if (chat.isAdmin(currentUserId) && userId != currentUserId) {
  IconButton(
    icon: Icon(Icons.remove_circle),
    onPressed: () => controller.removeMember(
      chatId: chat.id,
      userId: userId,
    ),
  );
}
```

### Member List with Admin Management
```dart
ListView.builder(
  itemCount: memberIds.length,
  itemBuilder: (context, index) {
    final memberId = memberIds[index];
    final isAdmin = chat.isAdmin(memberId);
    
    return ListTile(
      title: Text(memberId),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Admin badge
          if (isAdmin) Chip(label: Text('Admin')),
          
          // Promote/Demote button (for admins only)
          if (chat.isAdmin(currentUserId) && memberId != currentUserId)
            IconButton(
              icon: Icon(isAdmin ? Icons.arrow_downward : Icons.arrow_upward),
              onPressed: () async {
                if (isAdmin) {
                  await controller.demoteFromAdmin(
                    chatId: chat.id,
                    userId: memberId,
                  );
                } else {
                  await controller.promoteToAdmin(
                    chatId: chat.id,
                    userId: memberId,
                  );
                }
              },
            ),
        ],
      ),
    );
  },
);
```

## Error Handling

### Cannot Demote Last Admin
```dart
try {
  await controller.demoteFromAdmin(chatId: chatId, userId: userId);
} catch (e) {
  if (e.toString().contains('Cannot demote the last admin')) {
    // Show error: At least one admin must remain
  }
}
```

### Insufficient Permissions
If a non-admin tries to perform admin actions, Supabase will return a permission error due to RLS policies. Handle these gracefully:

```dart
try {
  await controller.addMember(chatId: chatId, userId: newUserId);
} on PostgrestException catch (e) {
  if (e.code == '42501') {  // insufficient_privilege
    // Show error: Only admins can add members
  }
}
```

## Security Notes

1. **RLS Enforcement**: All permissions are enforced at the database level via Row Level Security (RLS) policies
2. **No Trust in Client**: Never rely solely on client-side checks - always let the database enforce permissions
3. **Trigger Safety**: Admin reassignment trigger ensures there's always at least one admin (if members remain)
4. **Self-Removal**: Users can always remove themselves from a chat, regardless of admin status
