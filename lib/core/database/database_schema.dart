// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Database Schema Definition
///
/// Defines the structure of the local SQLite database
class DatabaseSchema {
  static const int version = 10; // messages.is_incoming (local unread count)
  static const String databaseName = 'chattr.db';

  // Table names
  static const String chatsTable = 'chats';
  static const String messagesTable = 'messages';
  static const String syncMetadataTable = 'sync_metadata';
  static const String messageReactionsTable = 'message_reactions';
  static const String draftsTable = 'drafts';
  static const String kemPrekeysTable = 'kem_prekeys';

  // SQL to create chats table
  static const String createChatsTable = '''
    CREATE TABLE $chatsTable (
      id TEXT PRIMARY KEY,
      created_at TEXT NOT NULL,
      encrypted_data BLOB NOT NULL
    )
  ''';

  // SQL to create messages table. `is_favorite` (#4) is a local-only query
  // accelerator — the flag also round-trips inside the encrypted blob; this
  // indexed column just lets the favorites view select without decrypting all.
  //
  // `is_incoming` is the same idea for the unread count: 1 when the message was
  // sent by someone else (system messages included, matching what the server
  // used to count). Without it, counting unread would mean decrypting every row
  // to look at `sender_id`. It says only "this row came from someone else" —
  // strictly less than the `created_at` sitting next to it in the clear.
  static const String createMessagesTable = '''
    CREATE TABLE $messagesTable (
      id TEXT PRIMARY KEY,
      chat_id TEXT NOT NULL,
      created_at TEXT NOT NULL,
      encrypted_data BLOB NOT NULL,
      is_favorite INTEGER NOT NULL DEFAULT 0,
      is_incoming INTEGER NOT NULL DEFAULT 0
    )
  ''';

  // Indices for performance
  static const String createMessagesChatIdIndex = '''
    CREATE INDEX idx_messages_chat_id ON $messagesTable(chat_id)
  ''';

  static const String createMessagesFavoriteIndex = '''
    CREATE INDEX idx_messages_is_favorite ON $messagesTable(is_favorite)
  ''';

  /// v8→v9 migration: add the favorites column + index to an existing DB.
  static const List<String> migrateV8ToV9 = [
    'ALTER TABLE $messagesTable ADD COLUMN is_favorite INTEGER NOT NULL DEFAULT 0',
    'CREATE INDEX IF NOT EXISTS idx_messages_is_favorite ON $messagesTable(is_favorite)',
  ];

  /// Composite index for the unread count: the query filters one chat's
  /// incoming rows by timestamp, so all three columns belong in one index.
  static const String createMessagesUnreadIndex = '''
    CREATE INDEX idx_messages_unread
      ON $messagesTable(chat_id, is_incoming, created_at)
  ''';

  /// v9→v10 migration: add the direction column + unread index.
  ///
  /// Existing rows keep the `0` default — they are NOT backfilled, because
  /// the direction lives inside the encrypted blob and decrypting the whole
  /// store during a schema upgrade is neither cheap nor safe (the content key
  /// may be locked). The [unreadEpochKey] below is what makes that harmless.
  static const List<String> migrateV9ToV10 = [
    'ALTER TABLE $messagesTable ADD COLUMN is_incoming INTEGER NOT NULL DEFAULT 0',
    'CREATE INDEX IF NOT EXISTS idx_messages_unread '
        'ON $messagesTable($messagesUnreadIndexColumns)',
  ];

  static const String messagesUnreadIndexColumns =
      'chat_id, is_incoming, created_at';

  /// The unread count itself. Lives here rather than inline in the repository
  /// so the test drives the statement that actually ships instead of a retyped
  /// copy of it. Bind: chat id, then the ISO-8601 UTC read marker.
  static const String countUnreadSql =
      'SELECT COUNT(*) AS count FROM $messagesTable '
      'WHERE chat_id = ? AND is_incoming = 1 AND created_at > ?';

  /// Sentinel row in [syncMetadataTable] holding the instant the local unread
  /// count took over from the server's (v9→v10). Chats with no local read
  /// marker of their own count from this instant, so everything that existed
  /// before the upgrade is treated as read — exactly what migration 00053 did
  /// server-side when it introduced `last_read_at`.
  ///
  /// Deliberately absent on a FRESH install: there is nothing to declare read
  /// there, and messages fetched right after installing really are unread.
  static const String unreadEpochKey = '__unread_epoch__';

  static const String createMessagesCreatedAtIndex = '''
    CREATE INDEX idx_messages_created_at ON $messagesTable(created_at)
  ''';

  static const String createChatsCreatedAtIndex = '''
    CREATE INDEX idx_chats_created_at ON $chatsTable(created_at)
  ''';

  // SQL to create sync metadata table
  static const String createSyncMetadataTable = '''
    CREATE TABLE $syncMetadataTable (
      chat_id TEXT PRIMARY KEY,
      last_sync_timestamp TEXT NOT NULL
    )
  ''';

  // SQL to create message reactions table
  static const String createMessageReactionsTable =
      '''
    CREATE TABLE $messageReactionsTable (
      id TEXT PRIMARY KEY,
      message_id TEXT NOT NULL,
      user_id TEXT NOT NULL,
      reaction TEXT NOT NULL,
      created_at TEXT NOT NULL,
      UNIQUE(message_id, user_id, reaction)
    )
  ''';

  // SQL to create drafts table (unsent composer text per chat; the text is
  // stored inside the same encrypted blob format as chats/messages).
  static const String createDraftsTable = '''
    CREATE TABLE $draftsTable (
      chat_id TEXT PRIMARY KEY,
      updated_at TEXT NOT NULL,
      encrypted_data BLOB NOT NULL
    )
  ''';

  // SQL to create the one-time KEM prekey table (forward secrecy, audit P3).
  // Holds the PRIVATE halves of published one-time prekeys; the matching public
  // halves live server-side in `chat_member_prekeys`. A row is DELETED the
  // moment an incoming v5 message consumes its prekey — that deletion is the
  // forward-secrecy act (the logged ciphertext can no longer be unwrapped).
  //
  // The private key material lives in `encrypted_data` — the `{"x":..,"m":..}`
  // blob is encrypted via EncryptionService (AES-256-CBC under the same app-side
  // key that protects message content, itself in hardened secure storage). So a
  // private prekey is never at rest in cleartext, independent of whole-file
  // SQLCipher (M4). (CBC gives confidentiality-at-rest but not integrity — fine
  // here: tampering only corrupts the key, it can't forge one.) prekey_id/
  // chat_id/created_at are non-secret handles kept in the clear for lookup.
  static const String createKemPrekeysTable = '''
    CREATE TABLE $kemPrekeysTable (
      prekey_id TEXT PRIMARY KEY,
      chat_id TEXT NOT NULL,
      encrypted_data BLOB NOT NULL,
      created_at TEXT NOT NULL
    )
  ''';

  static const String createKemPrekeysChatIdIndex = '''
    CREATE INDEX idx_kem_prekeys_chat_id ON $kemPrekeysTable(chat_id)
  ''';

  // Indices for message reactions
  static const String createReactionsMessageIdIndex =
      '''
    CREATE INDEX idx_reactions_message_id ON $messageReactionsTable(message_id)
  ''';

  static const String createReactionsUserIdIndex =
      '''
    CREATE INDEX idx_reactions_user_id ON $messageReactionsTable(user_id)
  ''';

  // Prevent instantiation
  DatabaseSchema._();
}
