// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// The avatar cache sits on the SEND path — a donation runs after every message.
// So the properties that matter are not "does it download" but "does it stay out
// of the way": one fetch per URL ever, and every failure ending in null rather
// than an exception thrown into a send.

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:chattr/features/share_suggestions/share_suggestion_avatar_cache.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _pathProvider = MethodChannel('plugins.flutter.io/path_provider');

/// A PNG of [w]×[h] that is RED everywhere except for a GREEN square sitting
/// exactly where a centre crop of the shorter side would land.
///
/// That makes it an exact probe rather than an approximate one: a correct crop
/// is all green, a stretched picture pulls the red margins into the corners,
/// and an off-centre crop shows red along one edge. It works at any aspect
/// ratio — a banded picture only would have if the long side were at least
/// three times the short one, which the reported 286×451 is not.
Future<Uint8List> _centreMarkedPng(int w, int h) async {
  final side = (w < h ? w : h).toDouble();
  final recorder = ui.PictureRecorder();
  Canvas(recorder)
    ..drawRect(
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()..color = const Color(0xFFFF0000),
    )
    ..drawRect(
      Rect.fromLTWH((w - side) / 2, (h - side) / 2, side, side),
      Paint()..color = const Color(0xFF00FF00),
    );
  final picture = recorder.endRecording();
  final image = await picture.toImage(w, h);
  picture.dispose();
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

/// A solid single-colour PNG, for the cases where only the SIZE matters.
Future<Uint8List> _solidPng(int w, int h) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..color = const Color(0xFF00FF00),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(w, h);
  picture.dispose();
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

Future<ui.Image> _decode(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final image = (await codec.getNextFrame()).image;
  codec.dispose();
  return image;
}

/// The pixel at [x]/[y] as 0xAARRGGBB.
Future<int> _pixel(ui.Image image, int x, int y) async {
  final data = (await image.toByteData())!;
  final i = (y * image.width + x) * 4;
  return (data.getUint8(i + 3) << 24) |
      (data.getUint8(i) << 16) |
      (data.getUint8(i + 1) << 8) |
      data.getUint8(i + 2);
}

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

  late Uint8List png;

  setUpAll(() async {
    png = await _solidPng(64, 64);
  });

  test('no URL means no file, and no request', () async {
    serve(200, png);
    expect(await ShareSuggestionAvatarCache.pathFor(null), isNull);
    expect(await ShareSuggestionAvatarCache.pathFor(''), isNull);
    expect(requests, 0);
  });

  test('a downloaded avatar lands on disk', () async {
    serve(200, png);
    final path = await ShareSuggestionAvatarCache.pathFor('https://x/a.png');
    expect(path, isNotNull);
    expect(File(path!).existsSync(), isTrue);
    // No half-written leftovers: the download writes .part then renames.
    expect(File('$path.part').existsSync(), isFalse);
  });

  // The bug this guards (2026-08-08): iOS and Android clip the file into a
  // circle WITHOUT preserving the aspect ratio, so a portrait avatar arrived
  // squashed wide. Initials-circle contacts looked fine, which is what made it
  // look like a photo problem rather than a shape problem.
  group('the cached picture is square, whatever shape arrived', () {
    for (final (label, w, h) in [
      ('portrait', 60, 180),
      ('landscape', 180, 60),
      ('the reported 286×451', 286, 451),
    ]) {
      test('$label is centre-cropped, not stretched', () async {
        serve(200, await _centreMarkedPng(w, h));
        final path = await ShareSuggestionAvatarCache.pathFor('https://x/a.png');
        final image = await _decode(File(path!).readAsBytesSync());
        addTearDown(image.dispose);

        expect(image.width, image.height, reason: 'must be square');

        // Corners as well as centre: a stretch pulls the red margins into the
        // corners, an off-centre crop leaves red along one edge. Probed two
        // pixels in, because downscaling samples across the boundary and would
        // blend the outside colour into the outermost row.
        final last = image.width - 3;
        for (final (x, y) in [
          (2, 2),
          (last, 2),
          (2, last),
          (last, last),
          (image.width ~/ 2, image.height ~/ 2),
        ]) {
          final p = await _pixel(image, x, y);
          final r = (p >> 16) & 0xFF;
          final g = (p >> 8) & 0xFF;
          expect(
            g > 200 && r < 80,
            isTrue,
            reason: 'pixel $x/$y should be inside the centre square, was '
                '0x${p.toRadixString(16)}',
          );
        }
      });
    }

    test('a square avatar is left at its own size, not blown up', () async {
      serve(200, await _solidPng(32, 32));
      final path = await ShareSuggestionAvatarCache.pathFor('https://x/a.png');
      final image = await _decode(File(path!).readAsBytesSync());
      addTearDown(image.dispose);
      expect(image.width, 32);
      expect(image.height, 32);
    });

    test('an oversized avatar is scaled down to the render size', () async {
      serve(200, await _solidPng(1024, 1024));
      final path = await ShareSuggestionAvatarCache.pathFor('https://x/a.png');
      final image = await _decode(File(path!).readAsBytesSync());
      addTearDown(image.dispose);
      expect(image.width, 256);
      expect(image.height, 256);
    });
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
    expect(name, matches(RegExp(r'^[0-9a-f]{64}\.png$')));
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

    test('a body that is not an image at all', () async {
      // Falls back to the initials circle, which the caller reaches for when
      // this returns null — better than handing the OS a tile it cannot draw.
      serve(200, Uint8List.fromList(List<int>.filled(64, 7)));
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
