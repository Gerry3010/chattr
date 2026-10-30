# End-to-End Encryption Integration Guide

## Trust layer (2026-07, Security-Audit P0 — C1/H1/M3/H2)

On top of the hybrid KEM below, every account has one long-term **Ed25519
identity key** (`IdentityKeyManager`, secure storage, device-bound; on
recovery/reinstall a FRESH key is minted — Signal model):

- **Key authentication (C1):** every per-chat KEM public key is signed with
  the identity key, bound to the chatId (`KemKeyBinding`, extra `"s"` field in
  the `{"x","m"}` blob). Peers pin identity keys TOFU
  (`IdentityVerificationRepository`), upgrade to *verified* via QR scan (QR v2
  carries `ik`) or a Signal-style 60-digit **safety number**
  (`SafetyNumber`), and get a loud warning when a pinned key changes
  (`chatVerificationProvider` → shield badge + chat banner). Warn-only.
- **Envelope v4 (H1/M3/H2):** `{v:4, alg, ek, msg, sig}` —
  `sig` = identity signature over `chat_id‖sender_id‖message_id‖plaintext`
  (verified on every decrypt path, invalid ⇒ ⚠️-marker on the bubble);
  the AES-GCM DEM carries the same context as **AAD** (no splice/relabel);
  `ek` is prefixed with scheme byte `0x02` and decrypt rejects anything that
  is not full hybrid KEM (no silent X25519-only downgrade). v3 remains
  decrypt-only for old ciphertext. Byte layouts live in
  `lib/core/crypto/message_context.dart` and are mirrored in
  `mcp_server/src/crypto_port.ts` and
  `supabase/functions/insert-system-message/index.ts` (system messages: v4
  with sender `system`, no `sig` — clients exempt them). Cross-impl fixture:
  `web_crypto/testdata/interop_v4.json`.
- **Envelope v5 (P3 — forward secrecy):** `{v:5, alg, ek, pk, msg, sig}` —
  identical to v4 except `ek` wraps the message key to a **one-time prekey**
  (not the static chat key), and `pk` names the consumed prekey. Each member
  publishes a pool of identity-signed one-time hybrid KEM prekeys — public
  halves in the server table `chat_member_prekeys`, private halves in local
  SQLite `kem_prekeys` (`lib/features/prekeys/`, `PrekeyManager`). A sender
  **claims** one prekey per recipient via the atomic `claim_prekey` RPC
  (`SKIP LOCKED`, no double-claim) and wraps to it; a recipient decrypts once
  and then **deletes** the prekey's private half — after which the logged
  ciphertext is unwrappable by no one (forward secrecy). Deletion runs ONLY at
  the consume-once decrypt sites (`global_message_handler.handleNewMessage`/
  `_handleMessageEdit`, `messages_controller._fetchMissedMessages`), never on a
  local re-decrypt. No prekey / empty pool ⇒ fail-safe fallback to v4 — the same
  order-independent per-recipient gate as v3→v4. `crypto.go`/`web_crypto` are
  unchanged (the KEM wire format doesn't move); only the envelope shape adds
  `pk`, mirrored in `crypto_port.ts`. Cross-impl fixture:
  `web_crypto/testdata/interop_v5.json`. NOTE: prekey privates are in the
  cleartext DB until M4/SQLCipher (#119); the pool is kept small (~20) for that
  reason. Gives forward secrecy, not post-compromise self-healing (no ratchet).

## Status
✅ Infrastructure complete
⚠️ Controller integration pending

## What's Done
1. ✅ Supabase migration (`00002_e2e_encryption.sql`)
2. ✅ ChatKeyPairManager - hybrid (X25519 + ML-KEM-768) key management
3. ✅ MessageEncryptionService - hybrid KEM encryption/decryption
4. ✅ Updated Chat model with `memberKeys`
5. ✅ Updated Message model with `recipientId`, `encryptedContent`
6. ✅ Updated ChatsRepository with `updateMemberKeys()`
7. ✅ Updated MessagesRepository with `sendEncryptedMessage()`
8. ✅ Providers for encryption services

## What's Needed: Controller Integration

### 1. ChatsController Updates

**Add dependencies:**
```dart
final chatKeyManager = ref.read(chatKeyPairManagerProvider);
final chatsRepo = ChatsRepository(ref.read(supabaseClientProvider));
```

**On chat creation:**
```dart
Future<void> createChat(List<String> memberIds) async {
  // 1. Create chat on server
  final chat = await chatsRepo.createChat(memberIds);
  
  // 2. Generate hybrid key pair for this chat
  final keyPair = await chatKeyManager.generateKeyPairForChat(chat.id);
  final myPublicKey = await chatKeyManager.getPublicKey(chat.id);
  
  // 3. Add own public key to member_keys
  final memberKeys = {userId!: myPublicKey!};
  await chatsRepo.updateMemberKeys(chat.id, memberKeys);
  
  // 4. Broadcast NewChatEvent with chat ID to other members
  // They will generate their keys and add to member_keys
  
  // 5. Update local state
  state = [...state, chat.copyWith(memberKeys: memberKeys)];
}
```

**Handle ChatUpdate events (key exchange):**
```dart
eventBus!.on(EventType.chatUpdate, (event) async {
  if (event is ChatUpdateEvent && event.updates.containsKey('member_keys')) {
    // Another member added their public key
    final chat = state.firstWhere((c) => c.id == event.chatId);
    final updatedKeys = Map<String, String>.from(event.updates['member_keys']);
    
    // Update local chat with new keys
    state = state.map((c) => 
      c.id == chat.id ? c.copyWith(memberKeys: updatedKeys) : c
    ).toList();
  }
});
```

**On receiving NewChatEvent:**
```dart
Future<void> _handleNewChat(NewChatEvent event) async {
  // 1. Generate key pair for this chat
  final keyPair = await chatKeyManager.generateKeyPairForChat(event.chatId);
  final myPublicKey = await chatKeyManager.getPublicKey(event.chatId);
  
  // 2. Fetch current chat to get existing member_keys
  final chat = await chatsRepo.getChatById(event.chatId);
  if (chat == null) return;
  
  // 3. Add own public key
  final updatedKeys = {...chat.memberKeys, userId!: myPublicKey!};
  await chatsRepo.updateMemberKeys(event.chatId, updatedKeys);
  
  // 4. Add to local state
  if (!state.any((c) => c.id == chat.id)) {
    state = [...state, chat.copyWith(memberKeys: updatedKeys)];
  }
}
```

### 2. MessagesController Updates

**Add dependencies:**
```dart
final messageEncryption = ref.read(messageEncryptionServiceProvider);
final chatKeyManager = ref.read(chatKeyPairManagerProvider);
final chatsRepo = ChatsRepository(ref.read(supabaseClientProvider));
```

**On sending message:**
```dart
Future<void> sendMessage(String senderId, String content) async {
  // 1. Get chat with member keys
  final chat = await chatsRepo.getChatById(chatId);
  if (chat == null || chat.memberKeys.isEmpty) {
    throw Exception('Cannot send encrypted message: No member keys');
  }
  
  // 2. Encrypt for all members
  final encryptedForRecipients = await messageEncryption.encryptForAllMembers(
    content,
    chat.memberKeys,
  );
  
  // 3. Send to server (creates N rows)
  await repo.sendEncryptedMessage(
    chatId: chatId,
    senderId: senderId,
    encryptedForRecipients: encryptedForRecipients,
  );
  
  // Message will arrive via NewMessageEvent and be decrypted
}
```

**On loading messages:**
```dart
Future<void> _init() async {
  try {
    // Biometric auth...
    final authenticated = await biometricAuth.authenticate(...);
    if (!authenticated) return;
    
    // Load encrypted messages (only for current user)
    final encryptedMessages = await localRepo.loadMessages(chatId, limit: _pageSize);
    
    // Decrypt each message
    final decryptedMessages = <Message>[];
    final privateKeyPem = await chatKeyManager.getPrivateKey(chatId);
    
    if (privateKeyPem != null) {
      for (final msg in encryptedMessages) {
        try {
          final plaintext = await messageEncryption.decryptMessage(
            msg.encryptedContent,
            privateKeyPem,
          );
          decryptedMessages.add(msg.withDecryptedContent(plaintext));
        } catch (e) {
          // Skip messages that can't be decrypted
        }
      }
    }
    
    state = decryptedMessages;
    
    // Subscribe to events...
  } catch (e) {
    state = [];
  }
}
```

**On receiving NewMessageEvent:**
```dart
Future<void> _handleNewMessage(NewMessageEvent event) async {
  // Create message from event (already has encrypted content)
  final message = Message(
    id: event.messageId,
    chatId: event.chatId,
    senderId: event.senderId,
    recipientId: userId!, // This encrypted copy is for us
    encryptedContent: event.content, // Event should include encrypted content
    createdAt: event.timestamp,
  );
  
  // Decrypt
  final privateKeyPem = await chatKeyManager.getPrivateKey(event.chatId);
  if (privateKeyPem != null) {
    try {
      final plaintext = await messageEncryption.decryptMessage(
        message.encryptedContent,
        privateKeyPem,
      );
      
      final decryptedMessage = message.withDecryptedContent(plaintext);
      
      // Save to local storage (plaintext in encrypted local DB)
      await _saveToLocal(decryptedMessage);
      
      // Add to state
      if (!state.any((m) => m.id == message.id)) {
        state = [...state, decryptedMessage];
      }
    } catch (e) {
      // Decryption failed
    }
  }
}
```

### 3. Update NewMessageEvent

The `NewMessageEvent` needs to include the encrypted content:

```dart
class NewMessageEvent extends BusEvent {
  final String chatId;
  final String messageId;
  final String senderId;
  final String content;  // This is now encrypted content
  // ... rest of implementation
}
```

### 4. Local Storage

Messages stored locally should be **decrypted plaintext** (protected by local AES encryption):

```dart
// When saving to local DB:
await localRepo.saveMessage(message.withDecryptedContent(plaintext));

// Local DB structure stays same (stores decryptedContent as "content")
```

### 5. Migration Path

**For existing users:**
1. Run Supabase migration
2. Existing plaintext messages will fail (no `recipient_id`)
3. Options:
   - Fresh start (delete old messages)
   - Migration script to duplicate messages per member
   - Hybrid: Support both schemas temporarily

**Recommended:** Fresh start for beta/development

### 6. Testing Checklist

- [ ] User A creates chat with User B
- [ ] Both users generate key pairs
- [ ] Keys exchanged via ChatUpdate events
- [ ] User A sends message
- [ ] Message encrypted for both users
- [ ] User B receives and decrypts message
- [ ] Message displays correctly
- [ ] Messages stored decrypted in local DB
- [ ] Pagination works with encrypted messages
- [ ] User leaves chat → key removed from member_keys
- [ ] Cannot decrypt future messages after leaving

### 7. Event Bus Integration

**Server-side:** When message is inserted, broadcast to each recipient:

```sql
-- In message insert trigger
FOR member_id IN SELECT user_id FROM chat_members WHERE chat_id = NEW.chat_id LOOP
  -- Get encrypted content for this specific recipient
  SELECT encrypted_content INTO enc_content 
  FROM messages 
  WHERE id LIKE NEW.id || '-%' 
  AND recipient_id = member_id;
  
  PERFORM pg_notify(
    'user:' || member_id,
    json_build_object(
      'type', 'newMessage',
      'message_id', NEW.id,
      'chat_id', NEW.chat_id,
      'sender_id', NEW.sender_id,
      'content', enc_content,  -- Encrypted content
      'timestamp', NEW.created_at
    )::text
  );
END LOOP;
```

## Summary

The infrastructure is complete. The remaining work is:
1. Update ChatsController for key generation and exchange
2. Update MessagesController for encryption/decryption
3. Update Event types to include encrypted content
4. Add server-side triggers for event broadcasting
5. Test end-to-end flow

All the heavy lifting (hybrid KEM crypto, key management, DB schema) is done!
