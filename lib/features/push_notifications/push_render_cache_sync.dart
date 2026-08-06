// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../chats/chat_members_controller.dart' show chatMembersProvider;
import '../chats/chats_controller.dart';
import '../messages/global_search_controller.dart' show chatDisplayNameProvider;
import '../profiles/profile_helpers.dart' show optionalUsernameProvider;
import 'push_render_cache.dart';
import '../../core/logging/logger_service.dart';

/// Keeps [PushRenderCache] stocked from the foreground app.
///
/// The background isolate that renders a push can resolve an id only if the
/// name was written here first, so this runs where the app already knows every
/// name a push could plausibly arrive for: the chat list.
///
/// Deliberately best-effort. A missing name costs a generic notification, not a
/// missing one, so nothing here is worth failing a screen build over.
/// Write ONLY the localized wording the background isolate needs.
///
/// Split out from [syncPushRenderCache] for two reasons, both of which bit us.
/// It has nothing to do with chats, but sat behind that caller's "no chats yet"
/// guard — an account without chats therefore never got any wording. And after
/// an app update that ADDS template keys, the isolate falls back to the English
/// defaults for the new ones until this has run once; a push that arrives
/// before the user next opens the app would be in the wrong language. Hence:
/// on every app start, not only when a chat list happens to be built.
Future<void> syncPushRenderTemplates() async {
  await PushRenderCache.putTemplates(
    PushTemplates(
      newMessage: 'notifications.push_new_message'.tr(),
      newMessageUnknown: 'notifications.push_new_message_unknown'.tr(),
      newMessageImage: 'notifications.push_new_message_image'.tr(),
      newMessageVideo: 'notifications.push_new_message_video'.tr(),
      newMessageAudio: 'notifications.push_new_message_audio'.tr(),
      newMessageFile: 'notifications.push_new_message_file'.tr(),
      reaction: 'notifications.push_reaction'.tr(),
      reactionUnknown: 'notifications.push_reaction_unknown'.tr(),
      memberRequestTitle: 'notifications.new_join_request'.tr(),
      memberRequestBody: 'notifications.wants_to_join'.tr(),
      chatFallback: 'notifications.push_chat_fallback'.tr(),
      someone: 'notifications.push_someone'.tr(),
    ),
  );
}

Future<void> syncPushRenderCache(WidgetRef ref) async {
  // The wording first: it never changes at runtime except on a locale switch,
  // and without it the isolate falls back to English.
  await syncPushRenderTemplates();

  final names = <String, String>{};
  for (final chat in ref.read(chatsControllerProvider)) {
    // Same resolver the chat list itself renders with — a notification that
    // named a chat differently from the row it belongs to would be worse than
    // no name at all.
    names[chat.id] = ref.read(chatDisplayNameProvider(chat.id));

    // Senders are ids in the payload, so every member needs an entry too.
    // Only names already loaded: this must not fan out into network requests
    // on a screen build.
    final members =
        ref.read(chatMembersProvider(chat.id)).asData?.value ??
        const <String>[];
    for (final memberId in members) {
      final username = ref.read(optionalUsernameProvider(memberId));
      if (username != null && username.isNotEmpty) names[memberId] = username;
    }
  }

  logger.info(
    'push cache: writing ${names.length} names '
    '(${ref.read(chatsControllerProvider).length} chats)',
    tag: 'PushRenderCache',
  );
  await PushRenderCache.putNames(names);
}
