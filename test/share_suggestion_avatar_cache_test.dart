// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// The avatar cache sits on the SEND path — a donation runs after every message.
// So the properties that matter are not "does it download" but "does it stay out
// of the way": one fetch per URL ever, and every failure ending in null rather
// than an exception thrown into a send.

import 'dart:io';
import 'dart:typed_data';

import 'package:chattr/features/share_suggestions/share_suggestion_avatar_cache.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _pathProvider = MethodChannel('plugins.flutter.io/path_provider');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  var requests = 0;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('avatar_cache_test');
    requests = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProvider, (call) async => tmp.path);
    ShareSuggestionAvatarCache.debugResetMemo();
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProvider, null);
    ShareSuggestionAvatarCache.debugClient = null;
    ShareSuggestionAvatarCache.debugResetMemo();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  void serve(int status, Uint8List body) {
    ShareSuggestionAvatarCache.debugClient = MockClient((_) async {
      requests++;
      return http.Response.bytes(body, status);
    });
  }

  final png = Uint8List.fromList(List<int>.filled(64, 7));

  test('no URL means no file, and no request', () async {
    serve(200, png);
    expect(await ShareSuggestionAvatarCache.pathFor(null), isNull);
    expect(await ShareSuggestionAvatarCache.pathFor(''), isNull);
    expect(requests, 0);
  });

  test('a downloaded avatar lands on disk and its bytes survive', () async {
    serve(200, png);
    final path = await ShareSuggestionAvatarCache.pathFor('https://x/a.png');
    expect(path, isNotNull);
    expect(File(path!).readAsBytesSync(), png);
    // No half-written leftovers: the download writes .part then renames.
    expect(File('$path.part').existsSync(), isFalse);
  });

  test('the same URL is fetched ONCE, however often a message is sent',
      () async {
    serve(200, png);
    for (var i = 0; i < 5; i++) {
      await ShareSuggestionAvatarCache.pathFor('https://x/a.png');
    }
    expect(requests, 1);
  });

  test('a cold start reuses the file on disk instead of re-downloading',
      () async {
    serve(200, png);
    final first = await ShareSuggestionAvatarCache.pathFor('https://x/a.png');
    ShareSuggestionAvatarCache.debugResetMemo(); // simulate a new app run
    final second = await ShareSuggestionAvatarCache.pathFor('https://x/a.png');
    expect(second, first);
    expect(requests, 1);
  });

  test('a different avatar is a different file', () async {
    serve(200, png);
    final a = await ShareSuggestionAvatarCache.pathFor('https://x/a.png');
    final b = await ShareSuggestionAvatarCache.pathFor('https://x/b.png');
    expect(a, isNot(b));
    expect(requests, 2);
  });

  test('the file name leaks nothing from the URL', () async {
    serve(200, png);
    const url = 'https://s/storage/v1/object/public/avatars/'
        '37db10fa-0059-4680-9655-3028d5166fc1/pic.png';
    final path = await ShareSuggestionAvatarCache.pathFor(url);
    final name = path!.split('/').last;
    expect(name, isNot(contains('37db10fa')));
    expect(name, isNot(contains('pic')));
    expect(name, matches(RegExp(r'^[0-9a-f]{64}$')));
  });

  group('every failure degrades to no picture, never to a throw', () {
    test('a non-200 response', () async {
      serve(404, png);
      expect(await ShareSuggestionAvatarCache.pathFor('https://x/a.png'), isNull);
    });

    test('an empty body', () async {
      serve(200, Uint8List(0));
      expect(await ShareSuggestionAvatarCache.pathFor('https://x/a.png'), isNull);
    });

    test('an oversized body is refused, not written', () async {
      serve(200, Uint8List(3 * 1024 * 1024));
      final path = await ShareSuggestionAvatarCache.pathFor('https://x/a.png');
      expect(path, isNull);
      expect(
        Directory('${tmp.path}/share_suggestion_avatars').existsSync(),
        isFalse,
        reason: 'refused downloads must not create the cache directory',
      );
    });

    test('a network error', () async {
      ShareSuggestionAvatarCache.debugClient =
          MockClient((_) async => throw const SocketException('offline'));
      expect(await ShareSuggestionAvatarCache.pathFor('https://x/a.png'), isNull);
    });

    test('a failed URL is not retried on every send', () async {
      ShareSuggestionAvatarCache.debugClient = MockClient((_) async {
        requests++;
        throw const SocketException('offline');
      });
      await ShareSuggestionAvatarCache.pathFor('https://x/a.png');
      await ShareSuggestionAvatarCache.pathFor('https://x/a.png');
      expect(requests, 1);
    });
  });

  test('clear() removes the pictures, not just the donations', () async {
    serve(200, png);
    final path = await ShareSuggestionAvatarCache.pathFor('https://x/a.png');
    expect(File(path!).existsSync(), isTrue);

    await ShareSuggestionAvatarCache.clear();

    expect(File(path).existsSync(), isFalse);
    expect(Directory('${tmp.path}/share_suggestion_avatars').existsSync(),
        isFalse);
    // And the memo went with it, so a later send fetches afresh.
    await ShareSuggestionAvatarCache.pathFor('https://x/a.png');
    expect(requests, 2);
  });
}
