// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

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

    test('avatars travel as LOCAL PATHS — the OS cannot fetch a URL', () async {
      await ShareSuggestionsChannel.donateSend(
        conversationId: 'c1',
        conversationName: 'Team',
        isGroup: true,
        recipients: const [
          ShareRecipient(
              id: 'u1', displayName: 'alice', avatarPath: '/cache/a'),
        ],
        conversationImagePath: '/cache/group',
      );
      final args = calls.single.arguments as Map;
      expect(args['conversationImagePath'], '/cache/group');
      expect((args['recipients'] as List).first,
          {'id': 'u1', 'displayName': 'alice', 'avatarPath': '/cache/a'});
    });

    test('a picture-less chat omits the key entirely, never sends null',
        () async {
      // The native sides treat "absent" as "no image". A literal null would
      // have to be special-cased on both, in two languages.
      await ShareSuggestionsChannel.donateSend(
        conversationId: 'c1',
        isGroup: false,
        recipients: const [ShareRecipient(id: 'u1', displayName: 'alice')],
      );
      final args = calls.single.arguments as Map;
      expect(args.containsKey('conversationImagePath'), isFalse);
      expect((args['recipients'] as List).first,
          isNot(contains('avatarPath')));
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

  group('ShareSuggestionsChannel on Android', () {
    final calls = <MethodCall>[];
    setUp(() {
      calls.clear();
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      _mockChannel(calls);
    });
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      _unmockChannel();
    });

    // Android publishes a conversation shortcut instead of donating an intent,
    // but that difference lives entirely in Kotlin: Dart must send the same
    // three calls with the same payload on both platforms.
    test('drives the same channel as iOS', () async {
      await ShareSuggestionsChannel.donateSend(
        conversationId: 'c1',
        conversationName: 'Team',
        isGroup: true,
        recipients: const [ShareRecipient(id: 'u1', displayName: 'alice')],
      );
      await ShareSuggestionsChannel.deleteConversations(['c1']);
      await ShareSuggestionsChannel.deleteAll();
      expect(calls.map((c) => c.method),
          ['donateSend', 'deleteConversations', 'deleteAll']);
      final args = calls.first.arguments as Map;
      expect(args['conversationId'], 'c1');
      expect(args.containsKey('content'), isFalse); // never any message content
    });

    // Withdrawal is the whole reason Android is hand-written instead of using
    // share_handler.recordSentMessage (which can only publish). If these two
    // ever stop reaching native, chat partners' names outlive the logout.
    test('deleteAll and deleteConversations reach native', () async {
      await ShareSuggestionsChannel.deleteAll();
      await ShareSuggestionsChannel.deleteConversations(['c1', 'c2']);
      expect(calls.map((c) => c.method), ['deleteAll', 'deleteConversations']);
      expect((calls[1].arguments as Map)['conversationIds'], ['c1', 'c2']);
    });
  });

  group('ShareSuggestionsChannel on an unsupported platform', () {
    test('no-ops on desktop — never touches the channel', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final calls = <MethodCall>[];
      _mockChannel(calls);
      expect(ShareSuggestionsChannel.isSupported, isFalse);
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

    test('isSupported covers exactly the platforms with a native handler', () {
      for (final p in [TargetPlatform.iOS, TargetPlatform.android]) {
        debugDefaultTargetPlatformOverride = p;
        expect(ShareSuggestionsChannel.isSupported, isTrue, reason: '$p');
      }
      for (final p in [
        TargetPlatform.linux,
        TargetPlatform.macOS,
        TargetPlatform.windows,
      ]) {
        debugDefaultTargetPlatformOverride = p;
        expect(ShareSuggestionsChannel.isSupported, isFalse, reason: '$p');
      }
      debugDefaultTargetPlatformOverride = null;
    });
  });

  // The Android Direct Share row is wired through three files that must agree.
  // Every way they can disagree fails SILENTLY: shortcuts get published, the
  // row stays empty, and nothing is logged. Asserting the joins here is the
  // only cheap place to catch it — the alternative is a device test.
  group('Android share-target wiring', () {
    final kotlin = File('android/app/src/main/kotlin/com/example/chattr/'
            'ShareSuggestionsChannel.kt')
        .readAsStringSync();
    final shortcutsXml =
        File('android/app/src/main/res/xml/shortcuts.xml').readAsStringSync();
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

    test('the shortcut category matches the <share-target> category', () {
      final fromKotlin = RegExp(r'SHARE_TARGET_CATEGORY\s*=\s*\n?\s*"([^"]+)"')
          .firstMatch(kotlin)
          ?.group(1);
      expect(fromKotlin, isNotNull,
          reason: 'SHARE_TARGET_CATEGORY constant not found');
      expect(shortcutsXml, contains('android:name="$fromKotlin"'),
          reason: 'shortcuts.xml declares a different category than the '
              'shortcuts we publish — the row would stay empty');
    });

    test('the manifest points at shortcuts.xml', () {
      expect(
        manifest,
        contains('android:name="android.app.shortcuts"'),
        reason: 'without this meta-data Android never reads <share-target>',
      );
      expect(manifest, contains('android:resource="@xml/shortcuts"'));
    });

    test('<share-target> targets the activity that receives ACTION_SEND', () {
      expect(shortcutsXml,
          contains('android:targetClass="net.geraldhofbauer.chattr.MainActivity"'));
      expect(manifest, contains('android:name=".MainActivity"'));
    });

    test('every shareable mime type is also offerable to a person', () {
      // A type in the intent filter but not in <share-target> can be shared to
      // the app, yet never to a contact — a split people would read as "the
      // suggestion is broken for photos".
      final mimes = RegExp(r'android:mimeType="([^"]+)"')
          .allMatches(manifest)
          .map((m) => m.group(1)!)
          .toSet();
      expect(mimes, contains('image/*'), reason: 'regex stopped matching');
      for (final mime in mimes) {
        expect(shortcutsXml, contains('android:mimeType="$mime"'),
            reason: '$mime is shareable to the app but not to a person');
      }
      expect(shortcutsXml, contains('android:mimeType="text/plain"'));
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
