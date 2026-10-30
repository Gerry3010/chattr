// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../features/chat_view/chat_view_controller.dart';
import '../../screens/chat/chat_view_screen.dart';
import 'app_page_route.dart';

/// Route name of an open conversation. Every push of a [ChatViewScreen] sets it
/// — otherwise [openChatAtMessage] cannot find the way back.
String chatRouteName(String chatId) => 'chat/$chatId';

/// Which conversations currently sit on the stack as a screen.
///
/// Flutter offers no way to ask whether a particular route still exists — and
/// `popUntil` with a predicate that never matches empties the stack down to the
/// root. Keeping this list is therefore not a luxury but the condition under
/// which jumping back may be attempted safely at all.
abstract final class OpenChats {
  static final _open = <String>{};

  static void enter(String chatId) => _open.add(chatId);
  static void leave(String chatId) => _open.remove(chatId);
  static bool isOpen(String chatId) => _open.contains(chatId);
}

/// Open a conversation and pulse a particular message there.
///
/// **Why this is a function of its own.** Favorites, the global search and the
/// media index all did the same thing: `Navigator.push(ChatViewScreen(...))`.
/// If one came from that very conversation — and that is the normal case, since
/// the media index hangs off its info — it afterwards lay on the stack
/// **twice**. That was visible in the doubled back navigation; worse was the
/// second effect: both instances listen to the same `highlightMessageNotifier`,
/// and the fork's jump run (p19) carries a single-scan token. Two readers
/// therefore cancel each other out — the jump ended up stuck. Reported by Gerry
/// on 2026-08-23.
///
/// If the conversation is already on the stack, it is popped back to and the
/// pulse triggered there; otherwise it is opened anew.
void openChatAtMessage(
  BuildContext context,
  WidgetRef ref, {
  required String chatId,
  required String messageId,
}) {
  final navigator = Navigator.of(context);

  if (OpenChats.isOpen(chatId)) {
    // `|| route.isFirst` is the safeguard: should the name be missing against
    // expectation (a future push that forgets it), the predicate stops at the
    // root at the latest — instead of clearing the whole stack.
    navigator.popUntil(
      (route) => route.settings.name == chatRouteName(chatId) || route.isFirst,
    );
    // One frame later: the screen has to be rebuilt first, otherwise the pulse
    // goes nowhere.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_pulseOnceLoaded(ref, chatId: chatId, messageId: messageId));
    });
    return;
  }

  navigator.push(
    appPageRoute<void>(
      settings: RouteSettings(name: chatRouteName(chatId)),
      builder: (_) => ChatViewScreen(
        chatId: chatId,
        highlightMessageId: messageId,
      ),
    ),
  );
}

/// Page older history in until the target message lies within the loaded window
/// — **only then** pulse.
///
/// `highlightMessage` is a silent failure when the message is not loaded
/// (`chat_view_controller.dart`), and the fork says so itself: "Paging older
/// history in is the HOST's job." On a **newly opened** chat `ChatViewScreen`
/// handles that; on an **already open** one there was nobody who did — so an
/// old favorite jumped nowhere, without an error turning up anywhere. Reported
/// by Gerry on 2026-08-23, right after the fix for the doubled chat.
///
/// The upper bound is the same as in the screen (100 pages); `hasMoreMessages`
/// normally ends the run long before. The 30 ms give the freshly loaded page
/// time to settle into the list instead of spinning tightly.
Future<void> _pulseOnceLoaded(
  WidgetRef ref, {
  required String chatId,
  required String messageId,
}) {
  final controller = ref.read(chatViewControllerProvider(chatId).notifier);
  return pageUntilLoaded(
    isLoaded: () => controller.chatController.initialMessageList.any(
      (m) => m.id == messageId,
    ),
    gibtNochMehr: () =>
        ref.read(chatViewControllerProvider(chatId)).hasMoreMessages,
    loadMore: controller.loadMoreMessages,
    pulsen: () => controller.highlightMessage(messageId),
  );
}

/// The run itself — deliberately without `ref`, so it is testable.
///
/// That it was not before is the reason the gap reached the field at all: what
/// was tested was only the bookkeeping of which chat is open, not the question
/// of whether anyone pages back at the destination.
///
/// Returns whether a pulse happened — `false` means: the message was not there
/// even after the end of the history.
@visibleForTesting
Future<bool> pageUntilLoaded({
  required bool Function() isLoaded,
  required bool Function() gibtNochMehr,
  required Future<void> Function() loadMore,
  required void Function() pulsen,
  int pages = 100,
  Future<void> Function() atemzug = _thirtyMilliseconds,
}) async {
  for (var rest = pages; rest > 0; rest--) {
    if (isLoaded()) {
      pulsen();
      return true;
    }
    if (!gibtNochMehr()) return false;
    await loadMore();
    await atemzug();
  }
  return false;
}

Future<void> _thirtyMilliseconds() =>
    Future<void>.delayed(const Duration(milliseconds: 30));
