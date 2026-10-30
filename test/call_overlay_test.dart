// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// The call screen appears over whatever is on screen, offers exactly the
// buttons the phase allows, and its buttons reach the controller.
// EasyLocalization is not loaded in the test: `.tr()` returns the key.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/core/events/event_bus_provider.dart';
import 'package:chattr/features/calls/call_controller.dart';
import 'package:chattr/features/calls/call_ice_config.dart';
import 'package:chattr/features/calls/call_keep_alive.dart';
import 'package:chattr/features/calls/call_log.dart';
import 'package:chattr/features/calls/call_log_writer.dart';
import 'package:chattr/features/calls/call_media.dart';
import 'package:chattr/features/calls/call_proximity.dart';
import 'package:chattr/features/calls/call_ringer.dart';
import 'package:chattr/features/calls/call_rules.dart';
import 'package:chattr/features/calls/call_signal.dart';
import 'package:chattr/features/calls/call_signaling.dart';
import 'package:chattr/features/profiles/avatar_url_cache.dart';
import 'package:chattr/features/profiles/profile_helpers.dart';
import 'package:chattr/screens/call/call_overlay.dart';

class _Signaling implements CallSignaling {
  final sent = <CallSignal>[];
  @override
  Future<bool> peerCanTakeCalls({
    required String chatId,
    required String peerId,
  }) async =>
      true;
  @override
  Future<void> send({
    required String chatId,
    required String peerId,
    required CallSignal signal,
    String? kind,
  }) async =>
      sent.add(signal);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Media implements CallMedia {
  CallAudioLevels levels = CallAudioLevels.silent;

  @override
  Future<CallAudioLevels> audioLevels() async => levels;

  final _s = StreamController<CallMediaStatus>.broadcast();
  @override
  Future<String> createOffer() async => 'O';
  @override
  Future<String> acceptOffer(String offerSdp) async => 'A';
  @override
  Future<void> applyAnswer(String answerSdp) async {}

  @override
  Future<void> prepareAnswer(String offerSdp) async {}

  @override
  Future<String> restartOffer() async => 'RESTART_OFFER';

  @override
  Future<String> answerRestart(String offerSdp) async => 'RESTART_ANSWER';
  @override
  Stream<CallMediaStatus> get status => _s.stream;
  @override
  void setMuted(bool muted) {}
  @override
  Future<void> setSpeaker(bool on) async {}
  @override
  Future<void> close() async {}
}

class _NoLog implements CallLogWriter {
  @override
  Future<void> write({
    required String chatId,
    required CallLogEntry entry,
    required DateTime at,
  }) async {}
}

class _FakeKeepAlive implements CallKeepAlive {
  bool active = false;
  @override
  void setActive(bool a) => active = a;

  final hangUps = StreamController<void>.broadcast();
  @override
  Stream<void> get hangUpRequests => hangUps.stream;
}

class _FakeProximity implements CallProximity {
  bool active = false;
  @override
  void setActive(bool a) => active = a;
}

class _Ringer implements CallRinger {
  bool ringback = false;
  @override
  void startRingback() => ringback = true;

  int endTones = 0;
  @override
  void playEndTone() => endTones++;

  @override
  void start() {}
  @override
  void stop() {}
}

class _Loader implements CallIceConfigLoader {
  @override
  Future<CallIceConfig> load({
    required String chatId,
    required String peerId,
  }) async =>
      const CallIceConfig();
}

void main() {
  late _Signaling signaling;
  late ProviderContainer c;

  Future<void> pump(
    WidgetTester tester, {
    Widget below = const Scaffold(body: Text('darunter')),
    bool aboveNavigator = false,
  }) async {
    signaling = _Signaling();
    c = ProviderContainer(overrides: [
      eventBusProvider.overrideWithValue(null),
      callSignalingProvider.overrideWithValue(signaling),
      callMediaFactoryProvider.overrideWithValue((_) => _Media()),
      callIceConfigLoaderProvider.overrideWithValue(_Loader()),
      callKeepAliveProvider.overrideWithValue(_FakeKeepAlive()),
      callLogWriterProvider.overrideWithValue(_NoLog()),
      callProximityProvider.overrideWithValue(_FakeProximity()),
      callRingerProvider.overrideWithValue(_Ringer()),
      profileProvider.overrideWith((ref, id) => null),
      avatarSignedUrlProvider.overrideWith((ref, args) => null),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      // aboveNavigator: mounted like in the app, in MaterialApp.builder,
      // where there is no Overlay above it. As `home` the Navigator's Overlay
      // is in scope, and a Tooltip that cannot build in the app passed here.
      child: aboveNavigator
          ? MaterialApp(
              builder: (context, child) => CallOverlayHost(child: child!),
              home: below,
            )
          : MaterialApp(home: CallOverlayHost(child: below)),
    ));
  }

  testWidgets('ohne Anruf ist nichts zu sehen', (tester) async {
    await pump(tester);
    expect(find.byType(CallScreen), findsNothing);
    expect(find.text('darunter'), findsOneWidget);
  });

  testWidgets('eingehend: Annehmen und Ablehnen, Annehmen beantwortet',
      (tester) async {
    await pump(tester);
    await tester.runAsync(() => c.read(callControllerProvider.notifier).handleSignal(
          chatId: 'chat',
          senderId: 'peer',
          signal: CallSignal(
              type: CallSignalType.invite,
              callId: 'c1',
              sentAt: DateTime.now(),
              sdp: 'OFFER'),
        ));
    await tester.pump();
    expect(find.byType(CallScreen), findsOneWidget);
    expect(find.text('call.incoming'), findsOneWidget);
    expect(find.byKey(const ValueKey('call_accept')), findsOneWidget);
    expect(find.byKey(const ValueKey('call_decline')), findsOneWidget);
    expect(find.byKey(const ValueKey('call_mute')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('call_accept')));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(c.read(callControllerProvider).phase, CallPhase.connecting);
    expect(signaling.sent.single.type, CallSignalType.accept);
    expect(find.byKey(const ValueKey('call_hang_up')), findsOneWidget);
    expect(find.byKey(const ValueKey('call_mute')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('call_hang_up')));
    await tester.pump();
    expect(find.text('call.ended.hangup'), findsOneWidget);

    // The end screen clears itself.
    await tester.pump(callEndScreenHold + const Duration(milliseconds: 10));
    expect(find.byType(CallScreen), findsNothing);
  });

  testWidgets('der Anruf nimmt dem Eingabefeld den Fokus, die Tastatur geht',
      (tester) async {
    // 2026-10-24: Nach dem Annehmen blieb die Tastatur über dem Anruf stehen,
    // weil das Eingabefeld unter dem Anrufbildschirm den Fokus behielt.
    await pump(tester,
        below: const Scaffold(body: TextField(autofocus: true)));
    await tester.pump();
    FocusNode field() =>
        tester.widget<EditableText>(find.byType(EditableText)).focusNode;
    expect(field().hasFocus, isTrue);

    await tester.runAsync(() => c.read(callControllerProvider.notifier).handleSignal(
          chatId: 'chat',
          senderId: 'peer',
          signal: CallSignal(
              type: CallSignalType.invite,
              callId: 'c1',
              sentAt: DateTime.now(),
              sdp: 'OFFER'),
        ));
    await tester.pump();
    expect(find.byType(CallScreen), findsOneWidget);
    expect(field().hasFocus, isFalse);
  });

  testWidgets('klingelnd verkleinert: Leiste mit Annehmen und Ablehnen',
      (tester) async {
    await pump(tester);
    await tester.runAsync(() => c.read(callControllerProvider.notifier).handleSignal(
          chatId: 'chat',
          senderId: 'peer',
          signal: CallSignal(
              type: CallSignalType.invite,
              callId: 'c1',
              sentAt: DateTime.now(),
              sdp: 'OFFER'),
        ));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('call_minimize')));
    await tester.pump();
    expect(find.byType(CallScreen), findsNothing);
    expect(find.byType(CallBar), findsOneWidget);
    expect(find.byKey(const ValueKey('call_bar_accept')), findsOneWidget);
    expect(find.byKey(const ValueKey('call_bar_decline')), findsOneWidget);
    expect(find.byKey(const ValueKey('call_bar_hang_up')), findsNothing);
    expect(find.text('darunter'), findsOneWidget, reason: 'die App ist frei');

    await tester.tap(find.byKey(const ValueKey('call_bar_accept')));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(c.read(callControllerProvider).phase, CallPhase.connecting);
    expect(signaling.sent.single.type, CallSignalType.accept);
    expect(find.byType(CallBar), findsOneWidget,
        reason: 'angenommen bleibt es die Leiste');
    expect(find.byKey(const ValueKey('call_bar_hang_up')), findsOneWidget);
    expect(find.byKey(const ValueKey('call_bar_accept')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('call_bar_hang_up')));
    await tester.pump(callEndScreenHold + const Duration(milliseconds: 10));
  });

  testWidgets('klingelnd verkleinert: Ablehnen aus der Leiste', (tester) async {
    await pump(tester);
    await tester.runAsync(() => c.read(callControllerProvider.notifier).handleSignal(
          chatId: 'chat',
          senderId: 'peer',
          signal: CallSignal(
              type: CallSignalType.invite,
              callId: 'c1',
              sentAt: DateTime.now(),
              sdp: 'OFFER'),
        ));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('call_minimize')));
    await tester.pump();
    Color barColor() => tester
        .widget<Material>(find
            .ancestor(
                of: find.byKey(const ValueKey('call_bar')),
                matching: find.byType(Material))
            .first)
        .color!;
    final ringingColor = barColor();
    expect(ringingColor, isNot(Colors.green.shade700));

    await tester.tap(find.byKey(const ValueKey('call_bar_decline')));
    await tester.pump();
    expect(c.read(callControllerProvider).phase, CallPhase.ended);
    expect(signaling.sent.single.type, CallSignalType.end);
    // 2026-10-24: Auf dem Weg hinaus blitzte die Leiste grün auf, wie ein
    // laufendes Gespräch. Sie behält die Farbe des Klingelns.
    expect(find.byType(CallBar), findsOneWidget);
    expect(barColor(), isNot(Colors.green.shade700));
    await tester.pump(callEndScreenHold + const Duration(milliseconds: 10));
  });

  testWidgets('über dem Navigator wie in der App: Anrufbildschirm und Leiste bauen',
      (tester) async {
    // 2026-10-24 (Mac-Claude): Im Debug-Build fiel der Anrufbildschirm sofort
    // in die Fehleransicht, weil Tooltips ein Overlay brauchen und über dem
    // Navigator keins liegt. Die übrigen Tests hängen den Anruf unter `home`
    // und sahen das deshalb nicht.
    await pump(tester, aboveNavigator: true);
    await tester.runAsync(() => c.read(callControllerProvider.notifier).handleSignal(
          chatId: 'chat',
          senderId: 'peer',
          signal: CallSignal(
              type: CallSignalType.invite,
              callId: 'c1',
              sentAt: DateTime.now(),
              sdp: 'OFFER'),
        ));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byType(CallScreen), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('call_minimize')));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byType(CallBar), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('call_bar_decline')));
    await tester.pump(callEndScreenHold + const Duration(milliseconds: 10));
    expect(tester.takeException(), isNull);
  });
}
