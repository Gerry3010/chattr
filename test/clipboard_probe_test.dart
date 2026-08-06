// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// The prompt-free iOS clipboard probe (PR #59). The point of the channel is
// that the composer menu stops calling SystemClipboard.read() on iOS — reading
// content is what triggers the iOS 16+ paste transparency banner. These tests
// pin the contract with the native side and the fallback behaviour everywhere
// else.
//
//   flutter test test/clipboard_probe_test.dart

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/features/media/clipboard_probe.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// Installs a fake native side; [probe] returns the map (or throws).
  void mockNative(Object? Function(MethodCall call) probe) {
    messenger.setMockMethodCallHandler(
      ClipboardProbe.channel,
      (call) async => probe(call),
    );
  }

  setUp(ClipboardProbe.resetForTesting);
  tearDown(() {
    messenger.setMockMethodCallHandler(ClipboardProbe.channel, null);
    ClipboardProbe.resetForTesting();
  });

  test('calls "probe" and reports an image on the clipboard', () async {
    final calls = <String>[];
    mockNative((call) {
      calls.add(call.method);
      return {
        'hasText': false,
        'hasImage': true,
        'hasUrl': false,
        'hasAny': true,
      };
    });

    expect(await ClipboardProbe.hasPasteableMedia(), isTrue);
    expect(calls, ['probe']);
  });

  test('text-only clipboard does NOT count as pasteable media', () async {
    // Would surface a media-paste entry that the authoritative read then can't
    // honour — the user taps "Einfügen" and gets "nothing to paste".
    mockNative((_) => {
          'hasText': true,
          'hasImage': false,
          'hasUrl': true,
          'hasAny': true,
        });

    expect(await ClipboardProbe.hasPasteableMedia(), isFalse);
  });

  test('empty clipboard reports false, not null', () async {
    mockNative((_) => {
          'hasText': false,
          'hasImage': false,
          'hasUrl': false,
          'hasAny': false,
        });

    expect(await ClipboardProbe.hasPasteableMedia(), isFalse);
  });

  test('no channel (Android/desktop/web) → null, i.e. use the fallback',
      () async {
    // No mock handler installed → MissingPluginException.
    expect(await ClipboardProbe.hasPasteableMedia(), isNull);
  });

  test('a channel-less platform is probed only once, then latched off',
      () async {
    expect(await ClipboardProbe.hasPasteableMedia(), isNull);

    // Even if a handler appeared afterwards, the latch keeps us on the portable
    // path for the rest of the session — no repeated failing invocations on
    // every menu open.
    mockNative((_) => {'hasImage': true});
    expect(await ClipboardProbe.hasPasteableMedia(), isNull);
  });

  test('native error → null (fall back rather than hide the entry)', () async {
    mockNative((_) => throw PlatformException(code: 'boom'));

    expect(await ClipboardProbe.hasPasteableMedia(), isNull);
  });

  test('a malformed payload degrades to "no media" rather than throwing',
      () async {
    mockNative((_) => <String, dynamic>{});

    expect(await ClipboardProbe.hasPasteableMedia(), isFalse);
  });
}
