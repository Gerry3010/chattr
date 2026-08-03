// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:typed_data';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../core/events/event_bus_provider.dart';
import '../../core/events/event_bus_service.dart';
import '../../core/events/event_types.dart';
import '../../core/lifecycle/app_lifecycle_service.dart';
import '../../core/logging/logger_service.dart';
import '../../core/security/biometric_auth_service.dart';
import '../../core/security/chat_key_pair_manager.dart';
import '../../core/security/kem_key_signer.dart';
import '../../core/security/prekey_manager.dart';
import '../../core/security/security_providers.dart';
import '../share_suggestions/share_suggestions_channel.dart';
import '../../core/supabase/supabase_client_provider.dart';
import '../auth/auth_controller.dart';
import '../mcp/mcp_auto_join_controller.dart';
import '../messages/drafts_repository.dart';
import '../messages/messages_controller.dart';
import '../messages/global_message_handler.dart';
import '../profiles/profiles_controller.dart';
import '../profiles/profiles_repository.dart';
import 'chat_member_keys_repository.dart';
import 'chat_members_controller.dart';
import 'chat_model.dart';
import 'new_chat_toast.dart';
import 'chats_local_provider.dart';
import 'chats_local_repository.dart';
import 'chats_repository.dart';
import 'lost_keys_provider.dart';

final chatsControllerProvider =
    StateNotifierProvider<ChatsController, List<Chat>>((ref) {
      final repo = ChatsRepository(ref.read(supabaseClientProvider));
      final memberKeysRepo = ref.read(chatMemberKeysRepositoryProvider);
      final localRepo = ref.read(chatsLocalRepositoryProvider);
      final biometricAuth = ref.read(biometricAuthServiceProvider);
      final keyManager = ref.read(chatKeyPairManagerProvider);
      final eventBus = ref.watch(eventBusProvider);
      final userId = ref.watch(authControllerProvider);
      return ChatsController(
        ref,
        repo,
        memberKeysRepo,
        localRepo,
        biometricAuth,
        keyManager,
        eventBus,
        userId,
      );
    });

final chatProvider = Provider.family.autoDispose<Chat?, String>((ref, chatId) {
  final chatsController = ref.watch(chatsControllerProvider);
  return chatsController.where((chat) => chat.id == chatId).firstOrNull;
});

/// Computes the `lastMessageAt` sort key for a chat the LOCAL user just sent
/// to, so it always floats to the top of the list.
///
/// The sender stamps its send timestamp from its own device clock, while every
/// other chat's sort key comes from a different device / the server. If the
/// local clock lags (or a media timestamp was captured at upload-start), the
/// raw local timestamp can be *older* than another chat's key and the just-sent
/// chat would stay stuck below it even after re-sorting. This returns a value
/// strictly newer than the newest OTHER chat whenever [lastMessageAt] isn't
/// already the maximum — otherwise it returns [lastMessageAt] unchanged.
@visibleForTesting
DateTime? bumpedSortTimestamp({
  required List<Chat> chats,
  required String chatId,
  required DateTime? lastMessageAt,
}) {
  if (lastMessageAt == null) return null;
  DateTime? maxOther;
  for (final c in chats) {
    if (c.id == chatId) continue;
    final d = c.sortDate;
    if (maxOther == null || d.isAfter(maxOther)) maxOther = d;
  }
  if (maxOther != null && !lastMessageAt.isAfter(maxOther)) {
    return maxOther.add(const Duration(milliseconds: 1));
  }
  return lastMessageAt;
}

/// ChatList ordering: pinned chats first (#3), then most-recent by [Chat.sortDate].
/// A single source of truth so every sort site (load, refresh, metadata bump)
/// agrees on the order.
int compareChatsForList(Chat a, Chat b) {
  if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
  return b.sortDate.compareTo(a.sortDate);
}

class ChatsController extends StateNotifier<List<Chat>> {
  final Ref ref;
  final ChatsRepository repo;
  final ChatMemberKeysRepository memberKeysRepo;
  final ChatsLocalRepository localRepo;
  final BiometricAuthService biometricAuth;
  final ChatKeyPairManager keyManager;
  final EventBusService? eventBus;
  final String? userId;

  StreamSubscription<BusEvent>? _eventSub;
  StreamSubscription<void>? _resumeSub;
  StreamSubscription<void>? _resubscribedSub;

  /// Guards against overlapping resyncs when the app rapidly pauses/resumes.
  bool _resyncing = false;
  bool _resyncQueued = false;

  /// Chats the current user initiated locally (created / scanned-and-added).
  /// Their `newChat` — whether from the local addChat call or the echoed
  /// realtime broadcast — must NOT raise the "you were added" toast (#117);
  /// only chats someone ELSE adds me to (realtime-only, never marked) do.
  final Set<String> _selfInitiatedChatIds = {};

  /// Chats whose `mark_chat_read` RPC is still in flight (or failed): the
  /// server-side unread count is known-stale for them, so refreshChats forces
  /// their unread to 0 instead of resurrecting the badge mid-read. Cleared on
  /// RPC ack or when a genuinely new incoming message arrives.
  final Set<String> _pendingReadZero = {};

  ChatsController(
    this.ref,
    this.repo,
    this.memberKeysRepo,
    this.localRepo,
    this.biometricAuth,
    this.keyManager,
    this.eventBus,
    this.userId,
  ) : super([]) {
    if (userId != null && eventBus != null) {
      _init();
    }
  }

  Map<String, Chat> _stateMap = {};

  set stateMap(Map<String, Chat> value) {
    _stateMap = value;
    super.state = value.values.toList()
      ..sort(compareChatsForList);
  }

  @override
  set state(List<Chat> value) {
    super.state = value;
    _stateMap = Map.fromEntries(value.map((chat) => MapEntry(chat.id, chat)));
  }

  Map<String, Chat> get stateMap => _stateMap;

  Map<String, Chat> get chatsById =>
      Map.fromEntries(state.map((chat) => MapEntry(chat.id, chat)));

  /// Whether the biometric gate has already been passed this session. The
  /// controller is recreated whenever the event bus / auth providers change, so
  /// without this flag the user would be re-prompted for biometrics on every
  /// rebuild. Reset on logout via [resetBiometricGate].
  static bool _biometricUnlocked = false;

  /// Reset the biometric gate (call on logout so the next user re-authenticates).
  static void resetBiometricGate() => _biometricUnlocked = false;

  Future<void> _init() async {
    try {
      // Biometric gate — prompt only once per session, not on every rebuild.
      if (!_biometricUnlocked) {
        final authenticated = await biometricAuth.authenticate(
          localizedReason: 'Authenticate to load your chats',
        );
        if (!authenticated) {
          // Authentication failed - don't load data. Log it loudly: to the
          // user this looks like an empty chat list / "nothing decrypts".
          logger.warning(
            'Biometric gate blocked chat loading — list stays empty',
            tag: 'ChatsController',
          );
          return;
        }
        _biometricUnlocked = true;
      }

      // Load chats from local storage and sort by recency
      final chats = await localRepo.loadChats();
      // final initial = chats.values.toList()
      //   ..sort(compareChatsForList);
      // state = initial;
      stateMap = chats;

      // Initialize global message handler to process all incoming messages
      // This ensures messages are decrypted and saved even for closed chats
      ref.read(globalMessageHandlerProvider);

      // Silently join any MCP chats bound to this user (no-op unless MCP is
      // enabled — see McpAutoJoinController).
      ref.read(mcpAutoJoinControllerProvider);

      // Ensure this device has a long-term identity key BEFORE any per-chat key
      // is registered (each is identity-signed — audit C1). Generation is
      // local + fast (awaited); publishing it so peers can pin/verify is network
      // and deferred so it never blocks chat loading.
      await _ensureIdentityKey();
      unawaited(_publishIdentityKey());

      // Fetch chats from Supabase
      await refreshChats();

      // Backfill sender-side read receipts that fired while the app was closed
      // (the realtime broadcast was missed). Deferred via microtask so it never
      // blocks controller creation, and view-independent — it writes through the
      // local DB regardless of which screen is open.
      unawaited(Future.microtask(_reconcileSentReceipts));

      // Subscribe to chat-relevant events from the single event stream.
      _eventSub = eventBus!.eventStream.listen((event) {
        if (event is NewChatEvent) {
          _handleNewChat(event).then((v) => refreshChats([event.chatId]));
        } else if (event is ChatUpdateEvent) {
          refreshChats([event.chatId]);
        } else if (event is ChatDeletedEvent) {
          _handleChatDeleted(event);
        } else if (event is PendingMemberEvent) {
          _handlePendingMember(event);
        } else if (event is MembershipChangedEvent) {
          _handleMembershipChanged(event);
        } else if (event is MemberKeyRegisteredEvent) {
          // A co-member (e.g. a just-scanned peer) has now registered their
          // per-chat key. Refresh so the chat reflects it and a sender who was
          // blocked can send without reloading (#116). The send path re-fetches
          // keys itself, so refreshing chat state is the only action needed here.
          refreshChats([event.chatId]);
        }
      });

      // On resume from background: reconnect the (possibly dropped) realtime
      // channel and re-fetch chats so unread badges reflect messages that
      // arrived while we were away. As the sole owner of the event bus, this
      // controller also drives the channel reconnect for the whole app.
      _resumeSub = ref
          .read(appLifecycleServiceProvider)
          .onResume
          .listen((_) => _handleResume());

      // The realtime channel can also drop and recover WITHOUT an app-resume
      // (in-place socket blip while foregrounded, #121). When the bus re-joins,
      // catch up on whatever was broadcast during the dead window — the bus has
      // already reconnected, so this only backfills.
      _resubscribedSub =
          eventBus!.onResubscribed.listen((_) => _handleResubscribed());
    } catch (e, stackTrace) {
      logger.error(
        'Failed to initialize chats controller',
        tag: 'ChatsController',
        error: e,
        stackTrace: stackTrace,
      );
      stateMap = {};
    }
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    _resumeSub?.cancel();
    _resubscribedSub?.cancel();
    super.dispose();
  }

  /// Ask the app-global message handler to backfill sender-side receipts that
  /// were missed while this client was closed/backgrounded. Its own try/catch
  /// swallows failures, so this never throws into the lifecycle path.
  Future<void> _reconcileSentReceipts() =>
      ref.read(globalMessageHandlerProvider).reconcileSentReceipts();

  /// Reconnect realtime and re-fetch chats after returning from the background.
  Future<void> _handleResume() async {
    await eventBus?.reconnect();
    await _runCatchUp();
  }

  /// The realtime channel dropped and re-subscribed on its own while the app
  /// stayed foregrounded (#121). Same backfill as [_handleResume] but WITHOUT
  /// reconnecting — the bus already re-joined.
  Future<void> _handleResubscribed() => _runCatchUp();

  /// Coalesced catch-up: at most one runs at a time, but a request arriving
  /// while one is in flight queues exactly one re-run instead of being dropped.
  /// This matters under a rapid reconnect flap — a dropped catch-up would leave
  /// the newest missed window un-backfilled and re-open the #121 staleness.
  Future<void> _runCatchUp() async {
    if (_resyncing) {
      _resyncQueued = true;
      return;
    }
    _resyncing = true;
    try {
      do {
        _resyncQueued = false;
        await _catchUpFromRealtimeGap();
      } while (_resyncQueued);
    } catch (e, stackTrace) {
      logger.error(
        'Failed to catch up chats after realtime gap',
        tag: 'ChatsController',
        error: e,
        stackTrace: stackTrace,
      );
    } finally {
      _resyncing = false;
    }
  }

  /// Re-fetch everything a missed realtime window could have changed: chats /
  /// unread counts, sender-side receipts, and the admin / my-request queues.
  /// Shared by resume ([_handleResume]) and in-place resubscribe
  /// ([_handleResubscribed]).
  Future<void> _catchUpFromRealtimeGap() async {
    await refreshChats();

    // Receipts that landed while we weren't listening were broadcast to a client
    // that wasn't receiving — backfill our sent-message ticks now.
    await _reconcileSentReceipts();

    // Join requests ("Beitrittsanfragen") refresh only via the (possibly missed)
    // `pendingMember` broadcast, so re-fetch the admin queue for every chat we
    // administer — otherwise requests that arrived during the gap never show up.
    // Invalidate after refreshChats() so admin status is current.
    if (userId != null) {
      for (final chat in state) {
        if (chat.isAdmin(userId!)) {
          ref.invalidate(pendingMembersProvider(chat.id));
        }
      }
      // Our own outgoing requests may have been approved/rejected while away
      // (rejection sends no event to the requester at all), so re-fetch the
      // "my requests" overview too.
      ref.invalidate(myPendingRequestsProvider(userId!));
    }
  }

  Future<void> refreshChats([Iterable<String>? chatIds]) async {
    if (userId == null) return;

    // Accepted - refetch the chat to get updated metadata (unread counts, etc.)
    final chats = await repo.fetchChats(chatIds);
    logger.info(
      'refreshChats: server returned ${chats.length} chat(s)'
      '${chatIds == null ? '' : ' (requested: ${chatIds.length})'}',
      tag: 'ChatsController',
    );

    // Self-heal key registration: the `newChat` realtime broadcast is the only
    // thing that generates+registers our per-chat key pair, so a missed event
    // (reload, offline, race on join) would leave us permanently without a
    // registered public key and make the chat undecryptable in both directions.
    // Reconcile here so every chat we're a member of always has our current
    // hybrid public key on the server.
    for (final chat in chats) {
      await _ensureMyKeyRegistered(chat.id);
    }

    // Load from local storage
    final localChats = await localRepo.loadChats();

    // Merge server + local (pure, unit-tested). Crucially the server result is
    // taken into state for EVERY returned chat: the old diff only accepted
    // chats whose `updatedAt` moved, but a chat that merely received messages
    // never bumps `updatedAt` — its fresh unread count was written to the DB
    // yet DROPPED from state, so state and DB alternated (badge flicker
    // 118 ↔ 0 on every resume).
    final merged = mergeServerChats(
      localChats: localChats,
      serverChats: chats,
      pendingReadZero: _pendingReadZero,
    );

    // Save the server-refreshed entries to local storage
    for (final chat in chats) {
      await _saveToLocal(merged[chat.id]!);
    }

    final deletedChatIds = computeRemovedChatIds(
      requestedIds: chatIds,
      localChats: localChats,
      fetchedIds: chats.map((chat) => chat.id).toSet(),
      now: DateTime.timestamp(),
    );

    // Update state
    final newState = Map<String, Chat>.from(merged);
    for (final chatId in deletedChatIds) {
      newState.remove(chatId);
    }
    final sorted = newState.values.toList()
      ..sort(compareChatsForList);
    state = sorted;

    for (final chatId in deletedChatIds) {
      logger.info(
        'Chat $chatId no longer on server — removing locally',
        tag: 'ChatsController',
      );
      await _removeChatLocally(chatId);
    }
  }

  /// Pure merge of a server chat fetch over the local snapshot — the single
  /// source of truth for what `refreshChats` puts into state.
  ///
  /// Rules:
  ///  • Every server-returned chat lands in the result — the SERVER wins for
  ///    metadata (unreadCount, lastMessage…); local-only chats are kept.
  ///  • Preserve LOCAL state a refresh would otherwise clobber:
  ///    – the pin flag (#3) — server data never carries it;
  ///    – a newer local lastMessageAt from our OWN send — the server derives
  ///      last_message_at from RECEIVED messages only, so right after we send
  ///      it would regress and the chat drops down the list (00057 fixes the
  ///      server side too; this is the belt-and-braces guard).
  ///  • [pendingReadZero] chats are forced to unreadCount 0: the user opened
  ///    them but the `mark_chat_read` RPC hasn't been acknowledged yet, so the
  ///    server count is known-stale — without this, "server wins" would
  ///    resurrect the badge for the chat currently being read.
  @visibleForTesting
  static Map<String, Chat> mergeServerChats({
    required Map<String, Chat> localChats,
    required List<Chat> serverChats,
    required Set<String> pendingReadZero,
  }) {
    final merged = Map<String, Chat>.from(localChats);
    for (final c in serverChats) {
      final local = localChats[c.id];
      var m = c;
      if (local?.isPinned ?? false) m = m.copyWith(isPinned: true);
      final localTs = local?.lastMessageAt;
      if (localTs != null &&
          (m.lastMessageAt == null || localTs.isAfter(m.lastMessageAt!))) {
        m = m.copyWith(lastMessageAt: localTs);
      }
      if (pendingReadZero.contains(c.id)) {
        m = m.copyWith(unreadCount: 0);
      }
      merged[c.id] = m;
    }
    return merged;
  }

  /// Reconcile deletions: get_user_chats_with_metadata inner-joins our own
  /// chat_members row, so a chat missing from a successful fetch means it was
  /// deleted OR we were removed — the same two cases the realtime chatDeleted
  /// event covers. Without this, a missed event left the chat around forever.
  /// Only chats the fetch could have returned are candidates (a targeted
  /// refresh returns just the requested ids), and freshly inserted chats are
  /// skipped: their membership row may not be visible to a fetch that was
  /// already in flight when the chat was created.
  @visibleForTesting
  static List<String> computeRemovedChatIds({
    required Iterable<String>? requestedIds,
    required Map<String, Chat> localChats,
    required Set<String> fetchedIds,
    required DateTime now,
  }) {
    final candidateIds = requestedIds?.toSet() ?? localChats.keys.toSet();
    final createGrace = now.subtract(const Duration(minutes: 2));
    return candidateIds
        .where((id) => !fetchedIds.contains(id))
        .where((id) => localChats.containsKey(id))
        .where((id) => localChats[id]!.insertedAt.isBefore(createGrace))
        .toList();
  }

  /// Adds a new chat
  Future<void> addChat(String id) async {
    // This is the local, self-initiated entry (create / QR-add). Mark it so the
    // "you were added" toast (#117) is suppressed for it — see [_handleNewChat].
    _selfInitiatedChatIds.add(id);
    return await _handleNewChat(NewChatEvent(chatId: id));
  }

  /// Open the existing 1:1 with [peerId] if one exists, otherwise create it.
  /// Prevents duplicate direct chats when the same pair is added again (QR scan
  /// or manual ID). Returns the chat id and whether it already existed (so the
  /// UI can hint "chat already exists, opened" instead of implying a new one).
  Future<({String id, bool existed})> findOrCreateDirectChat(
    String peerId,
  ) async {
    if (userId == null) throw Exception('User not authenticated');
    final existing = await repo.findDirectChat(peerId, userId!);
    if (existing != null) {
      // Make sure it's present locally / in state before we navigate to it.
      if (!state.any((c) => c.id == existing)) {
        await addChat(existing);
      }
      logger.info(
        'Reusing existing direct chat $existing with $peerId',
        tag: 'ChatsController',
      );
      return (id: existing, existed: true);
    }
    final newChat = await repo.createChat([userId!, peerId], isGroup: false);
    await addChat(newChat.id);
    return (id: newChat.id, existed: false);
  }

  /// Create a new group chat with a name
  Future<String> createGroupChat({required String name}) async {
    if (userId == null) throw Exception('User not authenticated');

    try {
      // 1. Create chat with name (only current user as member initially)
      final chat = await repo.createChat([userId!], name: name);

      // 2. Generate key pair for this chat
      await keyManager.generateKeyPairForChat(chat.id);
      final myPublicKey = await keyManager.getPublicKey(chat.id);

      if (myPublicKey == null) {
        throw Exception('Failed to generate key pair');
      }

      // 3. Store own public key in chat_members (identity-signed, C1)
      await memberKeysRepo.setPublicKey(
        chatId: chat.id,
        userId: userId!,
        publicKeyPem: await _signMyKey(chat.id, myPublicKey),
      );

      // 4. Save to local storage
      await _saveToLocal(chat);

      // 5. Add to state
      state = [...state, chat];

      return chat.id;
    } catch (e, stackTrace) {
      logger.error(
        'Failed to create group chat',
        tag: 'ChatsController',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// Updates chat metadata (lastMessageAt and unreadCount).
  ///
  /// [bumpToTop] guarantees the chat floats to the very top of the list. Use it
  /// for the sender's OWN sends: the sender stamps `lastMessageAt` from its
  /// local device clock, while every other chat carries a timestamp minted by a
  /// different device / the server. A slow local clock (or a media upload whose
  /// timestamp was captured at upload-start) would otherwise leave the
  /// just-sent chat stuck *below* a chat with a faster clock, even though we
  /// re-sort. When set, the sort key is forced strictly above the current
  /// maximum whenever the incoming timestamp isn't already the newest.
  Future<void> updateChatMetadata({
    required String chatId,
    DateTime? lastMessageAt,
    bool incrementUnread = false,
    bool bumpToTop = false,
  }) async {
    try {
      // Find the chat in state
      final chatIndex = state.indexWhere((c) => c.id == chatId);
      if (chatIndex == -1) {
        logger.warning(
          'Cannot update metadata: Chat $chatId not found in state',
          tag: 'ChatsController',
        );
        return;
      }

      final chat = state[chatIndex];

      // A genuinely new incoming message ends the "known read" window — the
      // server count is authoritative again for this chat.
      if (incrementUnread) _pendingReadZero.remove(chatId);

      final effectiveLastMessageAt = bumpToTop
          ? bumpedSortTimestamp(
              chats: state,
              chatId: chatId,
              lastMessageAt: lastMessageAt ?? chat.lastMessageAt,
            )
          : lastMessageAt ?? chat.lastMessageAt;

      final updatedChat = chat.copyWith(
        lastMessageAt: effectiveLastMessageAt,
        unreadCount: incrementUnread ? chat.unreadCount + 1 : chat.unreadCount,
      );

      // Update in local storage
      await _saveToLocal(updatedChat);

      // Rebuild state by id — the index computed above may be stale after the
      // `await` (a concurrent emission could have reordered/resized `state`).
      final newState = [
        for (final c in state) c.id == chatId ? updatedChat : c,
      ]..sort(compareChatsForList);
      state = newState;

      logger.debug(
        'Updated chat $chatId metadata: lastMessageAt=${effectiveLastMessageAt?.toIso8601String()}, unreadCount=${updatedChat.unreadCount}, bumpToTop=$bumpToTop',
        tag: 'ChatsController',
      );
    } catch (e, stackTrace) {
      logger.error(
        'Failed to update chat metadata',
        tag: 'ChatsController',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// Toggles the local pin on a chat (#3): pinned chats sort to the very top of
  /// the ChatList. Local-only — persists in the encrypted blob, never touches
  /// the server (see [compareChatsForList] + the refresh-merge pin preservation).
  Future<void> togglePin(String chatId) async {
    final idx = state.indexWhere((c) => c.id == chatId);
    if (idx == -1) return;
    final updated = state[idx].copyWith(isPinned: !state[idx].isPinned);
    await _saveToLocal(updated);
    final newState = [
      for (final c in state) c.id == chatId ? updated : c,
    ]..sort(compareChatsForList);
    state = newState;
  }

  /// Resets the unread count for a chat (called when chat is opened/viewed)
  Future<void> resetUnreadCount(String chatId) async {
    // Until the RPC below is acknowledged, the server's unread count for this
    // chat is known-stale — mark it so refreshChats' "server wins" merge can't
    // resurrect the badge mid-read. Cleared on RPC success, or by a genuinely
    // NEW incoming message (updateChatMetadata), which makes the chat unread
    // again for real.
    _pendingReadZero.add(chatId);
    // Persist "opened this chat" server-side (private last_read_at, migration
    // 00053) so the badge doesn't re-derive to a phantom count from the RPC on
    // the next app start. MUST run even when the local count is already 0 — the
    // server side may still be stale (e.g. read receipts off never set read_at).
    // Fire-and-forget: a failure just risks a stale badge, never blocks the open.
    unawaited(
      repo.markChatRead(chatId).then((_) {
        _pendingReadZero.remove(chatId);
      }).catchError((Object e, StackTrace s) {
        // Keep the pendingReadZero guard: the server still thinks it's unread.
        logger.warning('markChatRead failed for $chatId: $e',
            tag: 'ChatsController');
      }),
    );
    try {
      final chatIndex = state.indexWhere((c) => c.id == chatId);
      if (chatIndex == -1) return;

      final chat = state[chatIndex];
      final updatedChat = chat.copyWith(unreadCount: 0);

      // ALWAYS re-zero local storage — the old early-return on an already-zero
      // STATE skipped this, leaving a stale non-zero count in the DB that the
      // next refresh happily restored (half of the 118↔0 flicker).
      await _saveToLocal(updatedChat);

      if (chat.unreadCount != 0) {
        final newState = List<Chat>.from(state);
        newState[chatIndex] = updatedChat;
        state = newState;
      }

      logger.debug(
        'Reset unread count for chat $chatId',
        tag: 'ChatsController',
      );
    } catch (e, stackTrace) {
      logger.error(
        'Failed to reset unread count',
        tag: 'ChatsController',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// Updates the name of a chat
  Future<void> updateChatName({required Chat chat, required String newName}) async {
    if (userId == null) throw Exception('User not authenticated');
    newName = newName.trim();
    // Use the CURRENT chat from state, not the (possibly stale) snapshot passed
    // in: a second consecutive edit otherwise compares against — and rebuilds
    // from — an outdated snapshot, so it silently no-ops until the screen is
    // reopened with fresh data.
    final current = state.firstWhere((c) => c.id == chat.id, orElse: () => chat);
    if (newName.isEmpty || current.name == newName || newName.length < 2) return;
    try {
      await repo.updateChatName(current.id, newName);
      final updated = current.copyWith(name: newName);
      await localRepo.saveChat(updated);
      state = state.map((c) => c.id == updated.id ? updated : c).toList();
    } catch (e, stackTrace) {
      logger.error(
        'Failed to update chat name',
        tag: 'ChatsController',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// Update the chat description / topic (admin only). An empty string clears
  /// it (stored as null).
  Future<void> updateChatDescription({
    required Chat chat,
    required String newDescription,
  }) async {
    if (userId == null) throw Exception('User not authenticated');
    final trimmed = newDescription.trim();
    final value = trimmed.isEmpty ? null : trimmed;
    // Current chat from state (not the stale snapshot) — same repeated-edit
    // no-op fix as updateChatName.
    final current = state.firstWhere((c) => c.id == chat.id, orElse: () => chat);
    if (current.description == value) return;
    try {
      await repo.updateChatDescription(current.id, value);
      final updated = current.copyWith(
        description: value,
        clearDescription: value == null,
      );
      await localRepo.saveChat(updated);
      state = state.map((c) => c.id == updated.id ? updated : c).toList();
    } catch (e, stackTrace) {
      logger.error(
        'Failed to update chat description',
        tag: 'ChatsController',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// Upload (or replace) a group's avatar (admin only, 00055). Uploads the
  /// bytes to the public `group-avatars` bucket and persists the object path on
  /// the chat. Returns the stored path, or null on failure.
  Future<String?> uploadGroupAvatar({
    required Chat chat,
    required Uint8List bytes,
    required String fileExtension,
    String contentType = 'image/jpeg',
  }) async {
    if (userId == null) throw Exception('User not authenticated');
    try {
      final path = await repo.uploadGroupAvatar(
        chatId: chat.id,
        bytes: bytes,
        fileExtension: fileExtension,
        contentType: contentType,
      );
      // Bump updatedAt so the cache-buster (?u=updatedAt) changes and the
      // uploader immediately sees the new picture instead of the cached one
      // (the object path is stable/upsert). The server trigger bumps it too.
      final updated =
          chat.copyWith(avatarPath: path, updatedAt: DateTime.now());
      await localRepo.saveChat(updated);
      state = state.map((c) => c.id == chat.id ? updated : c).toList();
      return path;
    } catch (e, stackTrace) {
      logger.error(
        'Failed to upload group avatar',
        tag: 'ChatsController',
        error: e,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  /// Remove a group's avatar (admin only): clears the path back to the initials
  /// fallback.
  Future<void> clearGroupAvatar({required Chat chat}) async {
    if (userId == null) throw Exception('User not authenticated');
    if (chat.avatarPath == null) return;
    try {
      await repo.clearGroupAvatar(chat.id);
      final updated = chat.copyWith(clearAvatar: true);
      await localRepo.saveChat(updated);
      state = state.map((c) => c.id == chat.id ? updated : c).toList();
    } catch (e, stackTrace) {
      logger.error(
        'Failed to clear group avatar',
        tag: 'ChatsController',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// Set this chat's disappearing-messages TTL (seconds; null disables it).
  Future<void> updateMessageTtl({
    required Chat chat,
    required int? ttlSeconds,
  }) async {
    if (userId == null) throw Exception('User not authenticated');
    try {
      await repo.updateMessageTtl(chat.id, ttlSeconds);
      final updated = ttlSeconds == null
          ? chat.copyWith(clearMessageTtl: true)
          : chat.copyWith(messageTtlSeconds: ttlSeconds);
      await localRepo.saveChat(updated);
      state = state.map((c) => c.id == chat.id ? updated : c).toList();
      logger.info(
        '⏳ Set message TTL for chat ${chat.id} to ${ttlSeconds ?? 'off'}',
        tag: 'ChatsController',
      );
    } catch (e, stackTrace) {
      logger.error(
        'Failed to update message TTL',
        tag: 'ChatsController',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// Deletes a chat
  Future<bool> deleteChat(String chatId, {bool localOnly = false}) async {
    try {
      if (!localOnly) {
        final deleted = await repo.deleteChat(chatId);
        if (!deleted) {
          // RLS filtered the delete to zero rows (not an admin). Keep the
          // local copy — deleting it anyway would just have refreshChats
          // resurrect the chat from the server on the next sync.
          logger.warning(
            'Server did not delete chat $chatId (no permission?)',
            tag: 'ChatsController',
          );
          return false;
        }
      }
      await _removeChatLocally(chatId);
      // Delete key pair
      await keyManager.deleteKeyPair(chatId);
      ref.read(messagesControllerProvider(chatId).notifier).deleteMessagesForChat(chatId);
      // Drop any iOS Share-Suggestions donation for this conversation.
      await ShareSuggestionsChannel.deleteConversations([chatId]);
      return true;
    } catch (e, stackTrace) {
      logger.error(
        'Failed to delete chat',
        tag: 'ChatsController',
        error: e,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  /// Ensure our own per-chat hybrid key pair exists locally AND that the
  /// matching public key is registered in `chat_members`. Idempotent and
  /// safe to call on every refresh: it only writes when the server copy is
  /// missing or stale (e.g. a legacy RSA key from before the PQC migration).
  /// Ensure a long-term identity key exists on this device (generate on first
  /// run). Local + fast; peers rely on it to verify our per-chat keys.
  Future<void> _ensureIdentityKey() async {
    try {
      await ref.read(identityKeyManagerProvider).ensureKeyPair();
    } catch (e, stackTrace) {
      logger.error('Failed to ensure identity key',
          tag: 'ChatsController', error: e, stackTrace: stackTrace);
    }
  }

  /// Publish our identity public key to `profiles.identity_public_key` so
  /// co-members can pin it (TOFU) and verify our keys/signatures. Idempotent —
  /// only writes when the server copy differs, to avoid needless broadcasts.
  Future<void> _publishIdentityKey() async {
    if (userId == null) return;
    try {
      final pub =
          await ref.read(identityKeyManagerProvider).publicKeyBase64();
      if (pub == null) return;
      final existing = await ref
          .read(profilesControllerProvider.notifier)
          .getProfile(userId!);
      if (existing.identityPublicKey == pub) return;
      await ProfilesRepository(ref.read(supabaseClientProvider))
          .publishIdentityKey(userId: userId!, identityPublicKey: pub);
    } catch (e, stackTrace) {
      logger.error('Failed to publish identity key',
          tag: 'ChatsController', error: e, stackTrace: stackTrace);
    }
  }

  /// Attach an identity-key signature to our per-chat public-key blob, bound to
  /// [chatId], so peers can verify the server didn't swap the key (audit C1).
  /// Deterministic (Ed25519/RFC 8032), so re-signing the same key is idempotent.
  /// Falls back to the unsigned blob if signing fails — peers then see the key
  /// as "unverified" rather than the registration failing.
  Future<String> _signMyKey(String chatId, String publicBlob) =>
      ref.read(kemKeySignerProvider).sign(chatId, publicBlob);

  Future<void> _ensureMyKeyRegistered(String chatId) async {
    if (userId == null) return;
    try {
      // Fetch our currently-registered server key first — it is both the
      // re-mint guard below and the "did anything change?" comparison later.
      final registered = await memberKeysRepo.getPublicKey(
        chatId: chatId,
        userId: userId!,
      );

      if (!(await keyManager.hasKeyPair(chatId))) {
        // Local KEM key is gone. Distinguish a genuinely NEW chat (nothing
        // registered server-side yet) from a LOST key — secure storage got
        // wiped but we already registered a key (the Galaxy resetOnError
        // deleteAll class, #149). Regenerating over a loss would overwrite our
        // server key with a fresh one that can't decrypt in-flight ciphertext
        // AND fire a false `keys_rotated` alarm to every peer. So mint only for
        // a truly-new chat; a lost key defers (restore via recovery phrase).
        if (registered != null) {
          // Chat keys live only in local secure storage — the recovery phrase
          // re-establishes IDENTITY, not per-chat KEM keys. So we can't silently
          // recover; flag the chat so the chat view offers a deliberate rotate.
          logger.warning(
            'KEM key for chat $chatId missing locally but present on server — '
            'deferring (no re-mint / no keys_rotated). User must rotate a new '
            'key to resume decryptable messaging.',
            tag: 'ChatsController',
          );
          ref.read(lostKeysProvider.notifier).markLost(chatId);
          return;
        }
        await keyManager.generateKeyPairForChat(chatId);
      }
      final myPublicKey = await keyManager.getPublicKey(chatId);
      if (myPublicKey == null) return;
      final signed = await _signMyKey(chatId, myPublicKey);

      if (registered != signed) {
        await memberKeysRepo.setPublicKey(
          chatId: chatId,
          userId: userId!,
          publicKeyPem: signed,
        );
      }

      // Forward secrecy (P3): keep a pool of one-time prekeys published so peers
      // can send us v5 (per-message forward-secret) envelopes. Fire-and-forget —
      // topping the pool up means up to ~20 hybrid keygens + a publish, which
      // must NOT block chat open. The manager is captured synchronously (alive
      // ref) and owns its repos, so it survives if this controller disposes;
      // replenishIfLow swallows its own errors, and senders fall back to v4
      // while our pool is empty. So this never blocks or breaks key registration.
      unawaited(ref.read(prekeyManagerProvider).replenishIfLow(chatId, userId!));
    } catch (e, stackTrace) {
      logger.error(
        'Failed to ensure key registration for chat $chatId',
        tag: 'ChatsController',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// Rotate our per-chat key pair and register the new public key. New
  /// messages will be encrypted for the fresh key; the previous key is
  /// retained (one generation) so in-flight messages still decrypt. Old
  /// locally-stored messages are unaffected.
  Future<void> rotateChatKey(String chatId) async {
    if (userId == null) return;
    try {
      final newPublicKey = await keyManager.rotateKeyPairForChat(chatId);
      if (newPublicKey == null) return;
      await memberKeysRepo.setPublicKey(
        chatId: chatId,
        userId: userId!,
        publicKeyPem: await _signMyKey(chatId, newPublicKey),
      );
      // A deliberate rotate clears the lost-key state (#11): we now have a fresh
      // local private key registered, so messaging is decryptable again.
      ref.read(lostKeysProvider.notifier).clear(chatId);
      logger.info('Rotated key pair for chat $chatId', tag: 'ChatsController');
    } catch (e, stackTrace) {
      logger.error(
        'Failed to rotate key for chat $chatId',
        tag: 'ChatsController',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// Handle new chat event from event bus
  Future<void> _handleNewChat(NewChatEvent event) async {
    if (userId == null) return;
    try {
      // 1. Generate key pair for this chat
      if (!(await keyManager.hasKeyPair(event.chatId))) {
        // Same re-mint guard as _ensureMyKeyRegistered (#149): if secure storage
        // was wiped but we already registered a KEM key for this chat, do NOT
        // regenerate + overwrite — that fires a false `keys_rotated` to peers.
        // Only mint for a genuinely-new chat; a lost key defers to recovery.
        final registered = await memberKeysRepo.getPublicKey(
          chatId: event.chatId,
          userId: userId!,
        );
        if (registered != null) {
          logger.warning(
            'KEM key for new-chat ${event.chatId} missing locally but present '
            'on server — deferring (no re-mint / no keys_rotated).',
            tag: 'ChatsController',
          );
          ref.read(lostKeysProvider.notifier).markLost(event.chatId);
          return;
        }
        await keyManager.generateKeyPairForChat(event.chatId);
      }
      final myPublicKey = await keyManager.getPublicKey(event.chatId);

      if (myPublicKey == null) return;

      // 2. Fetch current chat
      final chat = await repo.getChatById(event.chatId);
      if (chat == null) return;

      // 3. Store own public key in chat_members (identity-signed, C1)
      await memberKeysRepo.setPublicKey(
        chatId: event.chatId,
        userId: userId!,
        publicKeyPem: await _signMyKey(event.chatId, myPublicKey),
      );

      // 4. Save to local storage
      await _saveToLocal(chat);

      // 5. Add to state if not already present
      if (state.any((c) => c.id == chat.id)) {
        state = state.map((c) => c.id == chat.id ? chat : c).toList();
      } else {
        state = [...state, chat];
      }

      // 6. Eagerly resolve member profiles so a 1:1's title shows the peer's
      // username immediately. The lazy profilesListProvider load can race a
      // freshly-created chat and negative-cache a member in
      // ProfilesController._nonExistingIds (a transient null fetch). Because the
      // retry check there keys on containsKey while loadProfiles skips
      // isProfileCached, such a member is then NEVER retried — leaving the chat
      // titled "Chat <id>" until an app restart. forceRefresh busts that cache;
      // invalidate re-fetches the member list in case it cached empty/partial.
      try {
        final memberIds =
            await ref.read(chatMembersRepositoryProvider).getChatMembers(chat.id);
        await ref
            .read(profilesControllerProvider.notifier)
            .loadProfiles(memberIds, forceRefresh: true);
        ref.invalidate(chatMembersProvider(chat.id));

        // 7. #117: if SOMEONE ELSE added me to this chat (i.e. it wasn't one I
        // initiated via addChat), raise a "you were added" toast with a "go to
        // chat" action. memberIds + profiles are freshly loaded here.
        if (!_selfInitiatedChatIds.contains(event.chatId)) {
          final String message;
          if (chat.isGroup) {
            message = 'chats.added_to_group'.tr(
              namedArgs: {'group': chat.name ?? 'chats.a_group'.tr()},
            );
          } else {
            final profiles = ref.read(profilesControllerProvider);
            final peerId = memberIds.firstWhere(
              (id) => id != userId,
              orElse: () => '',
            );
            final peerName = profiles[peerId]?.username ?? 'chats.someone'.tr();
            message = 'chats.added_you'.tr(namedArgs: {'name': peerName});
          }
          ref.read(newChatToastProvider.notifier).state =
              NewChatToast(chatId: chat.id, message: message);
        }
      } catch (e) {
        logger.warning(
          'Eager member-profile load for new chat ${chat.id} failed',
          tag: 'ChatsController',
          error: e,
        );
      }
    } catch (e, stackTrace) {
      logger.error(
        'Failed to handle new chat event',
        tag: 'ChatsController',
        error: e,
        stackTrace: stackTrace,
      );
    }

    // A just-approved user receives ONLY `newChat` — the server's
    // `membershipChanged` broadcast deliberately excludes the changed user, so
    // this is the sole place their "Warte auf Admin-Freigabe" banner can clear.
    // Re-fetch the membership providers the banner watches so isMember flips to
    // true and isPending to false (they are autoDispose FutureProviders that
    // only re-evaluate on invalidation), and drop the resolved outgoing request.
    final uid = userId;
    if (uid != null) {
      ref.invalidate(isMemberProvider((chatId: event.chatId, userId: uid)));
      ref.invalidate(
        isPendingMemberProvider((chatId: event.chatId, userId: uid)),
      );
      ref.invalidate(
        membershipStatusProvider((chatId: event.chatId, userId: uid)),
      );
      ref.invalidate(myPendingRequestsProvider(uid));
    }
  }

  /// Handle pending member event from event bus
  void _handlePendingMember(PendingMemberEvent event) {
    // Invalidate the pending members provider to refresh the UI
    ref.invalidate(pendingMembersProvider(event.chatId));

    logger.info(
      'Pending member request for chat ${event.chatId} from user ${event.userId}',
      tag: 'ChatsController',
    );
  }

  /// Handle membership changed event (when member list changes for existing members)
  void _handleMembershipChanged(MembershipChangedEvent event) {
    // Invalidate the chat members provider to refresh member lists
    ref.invalidate(chatMembersProvider(event.chatId));

    // Invalidate membership status for the affected user
    ref.invalidate(
      membershipStatusProvider((chatId: event.chatId, userId: event.userId)),
    );

    // A membership change means a pending request was resolved (approval turns a
    // pending row into a member). The `pendingMember` broadcast only fires on
    // NEW requests, never on resolution — so without this, a CO-admin's pending
    // list + badge keep showing an already-approved request until manual
    // refresh (the aggregated-view discrepancy, Task #102). Re-fetch the queue.
    ref.invalidate(pendingMembersProvider(event.chatId));

    // If it's our own membership status that changed, invalidate it specifically
    if (event.userId == userId) {
      ref.invalidate(
        membershipStatusProvider((chatId: event.chatId, userId: userId!)),
      );
      // Our own request just resolved (we were approved / added) → drop it from
      // the outgoing "my requests" overview.
      ref.invalidate(myPendingRequestsProvider(userId!));
    }

    // Forward secrecy: when ANOTHER member leaves/is removed, rotate our own
    // key so subsequent messages use a fresh key the departed member never had.
    if (event.action == 'left' && event.userId != userId) {
      rotateChatKey(event.chatId);
    }

    logger.info(
      'Membership changed for chat ${event.chatId}: ${event.action} user ${event.userId}',
      tag: 'ChatsController',
    );
  }

  /// Handle chat deleted event (when user is removed from a chat)
  Future<void> _handleChatDeleted(ChatDeletedEvent event) async {
    try {
      await _removeChatLocally(event.chatId);

      logger.info(
        'Chat ${event.chatId} deleted (user removed from chat)',
        tag: 'ChatsController',
      );
    } catch (e, stackTrace) {
      logger.error(
        'Failed to handle chat deleted event',
        tag: 'ChatsController',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// Removes a chat from the local database, in-memory state, and dependent
  /// providers — shared by explicit deletion, the realtime chatDeleted event,
  /// and the refresh reconciliation.
  Future<void> _removeChatLocally(String chatId) async {
    // Removes the chat + its cached messages from the local database.
    await localRepo.markChatAsDeleted(chatId);

    // Drop any unsent composer draft for the chat.
    await ref.read(draftsRepositoryProvider).deleteDraft(chatId);

    // Remove it from in-memory state so the UI updates immediately (the state
    // setter keeps _stateMap in sync).
    state = state.where((c) => c.id != chatId).toList();

    // Invalidate the chat members provider to refresh member lists
    ref.read(chatMembersControllerProvider).invalidateProviders(chatId, userId);
  }


  /// Save chat to local storage
  Future<void> _saveToLocal(Chat chat) async {
    try {
      await localRepo.saveChat(chat);
    } catch (e, stackTrace) {
      logger.error(
        'Failed to save chat to local storage',
        tag: 'ChatsController',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }
}
