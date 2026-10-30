// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chattr/features/auth/auth.dart';
import 'package:chattr/features/messages/message_model.dart';
import 'package:chattr/features/messages/messages_controller.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../core/logging/logger_service.dart';
import '../profiles/profiles_controller.dart';

/// Service for creating system messages
class SystemMessageService {
  final Ref _ref;
  final String _currentUserId;


  SystemMessageService(this._ref, this._currentUserId);

  /// Create a "member joined" system message
  Future<void> createMemberJoinedMessage({
    required String chatId,
    required String userId,
  }) async {
    try {
      // Get username
      final profilesController = _ref.read(profilesControllerProvider.notifier);
      final profile = await profilesController.getProfile(userId);
      final username = profile.username;

      final message = 'system_messages.member_joined'.tr(args: [username]);

      await _createSystemMessage(chatId: chatId, content: message);
    } catch (e) {
      // Log error but don't throw - system messages are not critical
      logger.error('Error creating member joined message: $e');
    }
  }

  /// Create a "member left" system message
  Future<void> createMemberLeftMessage({
    required String chatId,
    required String userId,
  }) async {
    try {
      // Get username
      final profilesController = _ref.read(profilesControllerProvider.notifier);
      final profile = await profilesController.getProfile(userId);
      final username = profile.username;

      final message = 'system_messages.member_left'.tr(args: [username]);

      await _createSystemMessage(chatId: chatId, content: message);
    } catch (e) {
      logger.error('Error creating member left message: $e');
    }
  }

  /// Create a "member was promoted to admin" system message
  Future<void> createMemberPromotedMessage({
    required String chatId,
    required String userId,
  }) async {
    try {
      final profilesController = _ref.read(profilesControllerProvider.notifier);
      final profile = await profilesController.getProfile(userId);
      final username = profile.username;

      final message = 'system_messages.member_promoted'.tr(args: [username]);

      await _createSystemMessage(chatId: chatId, content: message);
    } catch (e) {
      logger.error('Error creating member promoted message: $e');
    }
  }

  /// Create a "member was demoted from admin" system message
  Future<void> createMemberDemotedMessage({
    required String chatId,
    required String userId,
  }) async {
    try {
      final profilesController = _ref.read(profilesControllerProvider.notifier);
      final profile = await profilesController.getProfile(userId);
      final username = profile.username;

      final message = 'system_messages.member_demoted'.tr(args: [username]);

      await _createSystemMessage(chatId: chatId, content: message);
    } catch (e) {
      logger.error('Error creating member demoted message: $e');
    }
  }

  /// Create a "chat was created" system message
  Future<void> createChatCreatedMessage({
    required String chatId,
    required String creatorId,
  }) async {
    try {
      final profilesController = _ref.read(profilesControllerProvider.notifier);
      final profile = await profilesController.getProfile(creatorId);
      final username = profile.username;

      final message = 'system_messages.chat_created'.tr(args: [username]);

      await _createSystemMessage(chatId: chatId, content: message);
    } catch (e) {
      logger.error('Error creating chat created message: $e');
    }
  }

  /// Internal method to create a system message in the database
  Future<String> _createSystemMessage({
    required String chatId,
    required String content,
  }) async {
    const uuid = Uuid();
    final messageId = uuid.v4();
    final createdAt = DateTime.timestamp();

    final messagesController = _ref.read(messagesControllerProvider(chatId).notifier);
    await messagesController.addMessage(SystemMessage(
      id: messageId,
      chatId: chatId,
      recipientId: _currentUserId,
      createdAt: createdAt,
      decryptedContent: content,
    ));


    // final supabase = _ref.read(supabaseClientProvider);
    // final encryptionService = _ref.read(messageEncryptionServiceProvider);
    // final members = _ref.read(chatMemberKeysRepositoryProvider);
    // final memberKeys = await members.getAllPublicKeys(chatId);

    // final encryptedContent = await encryptionService.encryptForAllMembers(
    //   content,
    //   memberKeys,
    // );
    // final messageRows = encryptedContent.entries.map((entry) {
    //   return {
    //     'id': messageId,
    //     'chat_id': chatId,
    //     'sender_id': null, // System messages have no sender
    //     'recipient_id': entry.key,
    //     'encrypted_content': entry.value,
    //     'message_type': 'system',
    //     'created_at': createdAt.toIso8601String(),
    //   };
    // }).toList();
    // await supabase.from('messages').insert(messageRows);

    return messageId;
  }
}

/// Provider for system message service
final systemMessageServiceProvider = Provider<SystemMessageService>((ref) {
  final userId = ref.watch(authControllerProvider);
  if (userId == null) {
    throw StateError('System message service requires authenticated user');
  }
  return SystemMessageService(ref, userId);
});
