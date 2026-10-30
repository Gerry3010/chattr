// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Widget test for the multi-select forward/share chat picker (1.11): selecting
// several chats returns ALL their ids in selection order via the send button;
// the single-select mode still returns exactly one id on tap.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/features/profiles/avatar_url_cache.dart';
import 'package:chattr/features/auth/auth_controller.dart';
import 'package:chattr/features/chats/chat_model.dart';
import 'package:chattr/features/chats/chats_controller.dart';
import 'package:chattr/features/chats/chats_repository.dart';
import 'package:chattr/screens/chat/components/forward_chat_sheet.dart';

/// Minimal stand-ins: only the members the picker actually touches are real
/// (the `state` list from StateNotifier); everything else would throw.
class _FakeChatsController extends StateNotifier<List<Chat>>
    implements ChatsController {
  _FakeChatsController(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _FakeAuthController extends StateNotifier<String?>
    implements AuthController {
  _FakeAuthController() : super('me');

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _FakeChatsRepository implements ChatsRepository {
  @override
  String? groupAvatarUrl(String? avatarPath, {int? cacheBust}) => null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

Chat _group(String id, String name) => Chat(
      id: id,
      createdAt: DateTime.utc(2026, 7, 1),
      insertedAt: DateTime.utc(2026, 7, 1),
      name: name,
      isGroup: true,
    );

void main() {
  // Real UUID shapes — Chat.color parses the id's hex groups.
  const idA = 'aaaaaaaa-1111-4111-8111-111111111111';
  const idB = 'bbbbbbbb-2222-4222-8222-222222222222';
  final chats = [_group(idA, 'Alpha'), _group(idB, 'Beta')];

  Widget host({required bool multiSelect, required void Function(List<String>?) onResult}) {
    return ProviderScope(
      overrides: [
        chatsControllerProvider
            .overrideWith((ref) => _FakeChatsController(chats)),
        authControllerProvider.overrideWith((ref) => _FakeAuthController()),
        chatsRepositoryProvider.overrideWithValue(_FakeChatsRepository()),
        // Avatars come from a private bucket now: the real provider builds a
        // Supabase client to sign a URL. No picture in a widget test — the
        // initials circle is what renders.
        avatarSignedUrlProvider.overrideWith((ref, args) => null),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  final result = await showModalBottomSheet<List<String>>(
                    context: context,
                    builder: (_) => ForwardChatPicker(
                      excludeChatId: null,
                      titleKey: 'chat_view.forward_to',
                      multiSelect: multiSelect,
                    ),
                  );
                  onResult(result);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('multi-select returns all picked ids in selection order',
      (tester) async {
    List<String>? result;
    await tester.pumpWidget(
        host(multiSelect: true, onResult: (r) => result = r));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Send is disabled with nothing selected.
    final sendFinder = find.byKey(const ValueKey('forward_multi_send_button'));
    expect(
        tester.widget<FilledButton>(sendFinder).onPressed, isNull);

    // Pick Beta first, then Alpha — order must be preserved.
    await tester.tap(find.text('Beta'));
    await tester.pump();
    await tester.tap(find.text('Alpha'));
    await tester.pump();
    await tester.tap(sendFinder);
    await tester.pumpAndSettle();

    expect(result, [idB, idA]);
  });

  testWidgets('deselecting removes a chat from the result', (tester) async {
    List<String>? result;
    await tester.pumpWidget(
        host(multiSelect: true, onResult: (r) => result = r));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Alpha'));
    await tester.pump();
    await tester.tap(find.text('Beta'));
    await tester.pump();
    await tester.tap(find.text('Alpha')); // deselect again
    await tester.pump();
    await tester
        .tap(find.byKey(const ValueKey('forward_multi_send_button')));
    await tester.pumpAndSettle();

    expect(result, [idB]);
  });

  testWidgets('single-select pops with exactly the tapped chat',
      (tester) async {
    List<String>? result;
    await tester.pumpWidget(
        host(multiSelect: false, onResult: (r) => result = r));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();

    expect(result, [idA]);
  });
}
