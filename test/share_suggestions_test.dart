// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chattr/features/share_suggestions/share_suggestions_channel.dart';
import 'package:chattr/features/share_suggestions/share_suggestions_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = MethodChannel('net.geraldhofbauer.chattr/share_suggestions');

void _mockChannel(List<MethodCall> sink) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
    sink.add(call);
    return null;
  });
}

void _unmockChannel() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, null);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ShareRecipient.toMap', () {
    test('omits avatarPath when null, includes it when set', () {
      expect(const ShareRecipient(id: 'u1', displayName: 'alice').toMap(),
          {'id': 'u1', 'displayName': 'alice'});
      expect(
        const ShareRecipient(id: 'u1', displayName: 'alice', avatarPath: '/t/a.jpg')
            .toMap(),
        {'id': 'u1', 'displayName': 'alice', 'avatarPath': '/t/a.jpg'},
      );
    });
  });

  group('ShareSuggestionsChannel on iOS', () {
    final calls = <MethodCall>[];
    setUp(() {
      calls.clear();
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      _mockChannel(calls);
    });
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      _unmockChannel();
    });

    test('donateSend passes the right method + args (no content)', () async {
      await ShareSuggestionsChannel.donateSend(
        conversationId: 'c1',
        conversationName: 'Team',
        isGroup: true,
        recipients: const [
          ShareRecipient(id: 'u1', displayName: 'alice'),
          ShareRecipient(id: 'u2', displayName: 'bob'),
        ],
      );
      expect(calls, hasLength(1));
      expect(calls.single.method, 'donateSend');
      final args = calls.single.arguments as Map;
      expect(args['conversationId'], 'c1');
      expect(args['conversationName'], 'Team');
      expect(args['isGroup'], true);
      expect(args.containsKey('content'), isFalse); // never any message content
      expect((args['recipients'] as List).first,
          {'id': 'u1', 'displayName': 'alice'});
    });

    test('deleteAll + deleteConversations invoke their methods', () async {
      await ShareSuggestionsChannel.deleteAll();
      await ShareSuggestionsChannel.deleteConversations(['c1', 'c2']);
      expect(calls.map((c) => c.method), ['deleteAll', 'deleteConversations']);
      expect((calls[1].arguments as Map)['conversationIds'], ['c1', 'c2']);
    });

    test('a MissingPluginException from native is swallowed (never throws)',
        () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              _channel, (call) async => throw MissingPluginException('none'));
      await expectLater(
        ShareSuggestionsChannel.donateSend(
          conversationId: 'c1',
          isGroup: false,
          recipients: const [ShareRecipient(id: 'u1', displayName: 'a')],
        ),
        completes,
      );
    });
  });

  group('ShareSuggestionsChannel off iOS', () {
    test('no-ops on Android — never touches the channel', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final calls = <MethodCall>[];
      _mockChannel(calls);
      await ShareSuggestionsChannel.deleteAll();
      await ShareSuggestionsChannel.donateSend(
        conversationId: 'c1',
        isGroup: false,
        recipients: const [ShareRecipient(id: 'u1', displayName: 'a')],
      );
      expect(calls, isEmpty);
      debugDefaultTargetPlatformOverride = null;
      _unmockChannel();
    });
  });

  group('ShareSuggestionsController', () {
    final channelCalls = <MethodCall>[];
    setUp(() {
      channelCalls.clear();
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      _mockChannel(channelCalls);
    });
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      _unmockChannel();
    });

    test('default ON when nothing stored', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final c = ShareSuggestionsController(const FlutterSecureStorage());
      expect(await c.resolvedValue(), isTrue);
    });

    test('an explicit "false" disables it', () async {
      FlutterSecureStorage.setMockInitialValues(
          {'share_suggestions_enabled_v1': 'false'});
      final c = ShareSuggestionsController(const FlutterSecureStorage());
      expect(await c.resolvedValue(), isFalse);
    });

    test('setEnabled(false) persists AND wipes donations (deleteAll)', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final c = ShareSuggestionsController(const FlutterSecureStorage());
      await c.resolvedValue();
      await c.setEnabled(false);
      expect(c.state, isFalse);
      expect(channelCalls.map((e) => e.method), contains('deleteAll'));
      // A fresh controller reads the persisted 'false'.
      final reloaded = ShareSuggestionsController(const FlutterSecureStorage());
      expect(await reloaded.resolvedValue(), isFalse);
    });

    test('setEnabled(true) does NOT wipe donations', () async {
      FlutterSecureStorage.setMockInitialValues(
          {'share_suggestions_enabled_v1': 'false'});
      final c = ShareSuggestionsController(const FlutterSecureStorage());
      await c.resolvedValue();
      await c.setEnabled(true);
      expect(c.state, isTrue);
      expect(channelCalls.map((e) => e.method), isNot(contains('deleteAll')));
    });
  });
}
