// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chattr/features/settings/markdown_bar_controller.dart';
import 'package:chattr/screens/chat/components/chat_view_textfield.dart';
import 'package:chatview/chatview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';

/// A [MarkdownBarController] whose ctor never touches secure storage, so the
/// widget test doesn't hit `MissingPluginException` for the plugin channel.
class _StubMarkdownBar extends StateNotifier<bool> implements MarkdownBarController {
  _StubMarkdownBar() : super(false);
  @override
  Future<void> setEnabled(bool enabled) async => state = enabled;
  @override
  Future<void> toggle() => setEnabled(!state);
}

/// Regression guard for the chat text-field integration with the `chatview`
/// package. We inject [ChatViewTextField] through chatview's `sendMessageBuilder`;
/// the package wraps that builder in a `Builder(key: chatTextFieldViewKey)` to
/// measure the field's height. The field must therefore NOT also assign
/// `chatTextFieldViewKey` itself — doing so previously put the same GlobalKey on
/// two widgets, throwing "Multiple widgets used the same GlobalKey" ~2069x at
/// runtime. See lib/screens/chat/components/chat_view_textfield.dart.
void main() {
  Widget harness() {
    final controller = ChatController(
      initialMessageList: const [],
      scrollController: ScrollController(),
      currentUser: const ChatUser(id: 'me', name: 'Me'),
      otherUsers: const [ChatUser(id: 'other', name: 'Other')],
    );
    return ProviderScope(
      overrides: [
        markdownBarEnabledProvider.overrideWith((ref) => _StubMarkdownBar()),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: ChatView(
            chatController: controller,
            chatViewState: ChatViewState.hasMessages,
            featureActiveConfig: const FeatureActiveConfig(),
            onSendTap: (_, __, ___) {},
            sendMessageBuilder: (replyMessage) => ChatViewTextField(
              sendMessageConfig: const SendMessageConfiguration(
                allowRecordingVoice: false,
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets(
    'ChatViewTextField integrates without a duplicate GlobalKey',
    (tester) async {
      await tester.pumpWidget(harness());
      await tester.pump();
      // A duplicate chatTextFieldViewKey surfaces here as a caught FlutterError.
      expect(tester.takeException(), isNull);
      // The injected field actually rendered.
      expect(find.byType(ChatViewTextField), findsOneWidget);
    },
  );
}
