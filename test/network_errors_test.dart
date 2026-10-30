// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// CHAT-63: offline errors are said in words, screens stop spinning for 38 s,
// and a voice message survives a failed send.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' show ClientException;
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthRetryableFetchException, PostgrestException;

import 'package:chattr/core/events/event_bus_provider.dart';
import 'package:chattr/core/events/event_bus_service.dart';
import 'package:chattr/core/network/device_connectivity.dart';
import 'package:chattr/core/network/load_error_view.dart';
import 'package:chattr/core/network/network_errors.dart';
import 'package:chattr/features/media/media_attachment.dart';
import 'package:chattr/features/media/widgets/audio_recorder_button.dart';

class _Offline extends DeviceOfflineNotifier {
  @override
  bool build() => true;
  void back() => state = false;
}

void main() {
  group('isNetworkError', () {
    test('erkennt die Fehler der Supabase-Clients', () {
      expect(isNetworkError(ClientException('SocketException: x')), isTrue);
      expect(isNetworkError(AuthRetryableFetchException()), isTrue);
      expect(isNetworkError(TimeoutException('t')), isTrue);
      expect(
          isNetworkError(Exception('Failed host lookup: api.example')), isTrue);
    });

    test('eine Antwort des Servers ist kein Netzfehler', () {
      expect(isNetworkError(const PostgrestException(message: 'denied')),
          isFalse);
      expect(isNetworkError(StateError('kaputt')), isFalse);
    });
  });

  group('chattrRetry', () {
    test('Netzfehler: zweimal kurz, dann aufgeben', () {
      final e = ClientException('SocketException');
      expect(chattrRetry(0, e), isNotNull);
      expect(chattrRetry(1, e), isNotNull);
      expect(chattrRetry(2, e), isNull);
      expect(chattrRetry(0, e)! < const Duration(seconds: 1), isTrue);
    });

    test('alles andere wie Riverpods Standard', () {
      final e = Exception('server said no');
      expect(chattrRetry(5, e), isNotNull);
      expect(chattrRetry(10, e), isNull);
    });
  });

  testWidgets('LoadErrorView lädt neu, sobald das Netz zurück ist',
      (tester) async {
    var retries = 0;
    final offline = _Offline();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        deviceOfflineProvider.overrideWith(() => offline),
        serverConnectionProvider.overrideWith(
            (ref) => Stream.value(ServerConnection.unreachable)),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: LoadErrorView(
            error: ClientException('SocketException'),
            onRetry: () => retries++,
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('errors.no_connection'), findsOneWidget);
    expect(retries, 0);

    offline.back();
    await tester.pump();
    expect(retries, 1);

    await tester.tap(find.text('common.retry'));
    expect(retries, 2);
  });

  testWidgets('eine Sprachnachricht übersteht ein Senden ohne Netz',
      (tester) async {
    final sent = <OutgoingMedia>[];
    var online = false;
    Future<void> onSend({
      required List<OutgoingMedia> items,
      String? caption,
      void Function(double fraction)? onProgress,
      bool Function()? isCancelled,
      Object? quality,
      bool? asShot,
    }) async {
      if (!online) throw ClientException('SocketException: offline');
      sent.addAll(items);
    }

    final key = GlobalKey<ScaffoldMessengerState>();
    await tester.pumpWidget(MaterialApp(
      scaffoldMessengerKey: key,
      home: const Scaffold(body: SizedBox()),
    ));
    final voice = OutgoingMedia.bytes(
      Uint8List.fromList([1, 2, 3]),
      fileName: 'voice.m4a',
      mime: 'audio/mp4',
    );

    await sendVoiceOrOffer(onSend, voice, key.currentState!);
    await tester.pumpAndSettle(); // let the snack bar slide in before tapping
    expect(find.text('media.voice_not_sent_offline'), findsOneWidget);
    expect(sent, isEmpty);

    online = true;
    await tester.tap(find.text('media.send_again'));
    await tester.pumpAndSettle();
    expect(sent.single, same(voice));
  });
}
