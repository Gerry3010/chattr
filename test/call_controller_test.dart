// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// The controller carries out what call_rules decides. What is worth pinning
// here is the plumbing the rules can't see: that an offer actually goes out
// sealed as an invite, that the answer reaches the media layer, that the
// microphone is released on every way out, and that awaits racing a hangup
// don't resurrect a call.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/core/events/event_bus_provider.dart';
import 'package:chattr/core/events/event_types.dart';
import 'package:chattr/features/calls/call_controller.dart';
import 'package:chattr/features/calls/call_ice_config.dart';
import 'package:chattr/features/calls/call_keep_alive.dart';
import 'package:chattr/features/calls/call_log.dart';
import 'package:chattr/features/calls/call_log_writer.dart';
import 'package:chattr/features/calls/call_media.dart';
import 'package:chattr/features/calls/call_proximity.dart';
import 'package:chattr/features/calls/call_minimized.dart';
import 'package:chattr/features/calls/call_ringer.dart';
import 'package:chattr/features/calls/call_rules.dart';
import 'package:chattr/features/calls/call_signal.dart';
import 'package:chattr/features/calls/call_signaling.dart';
import 'package:chattr/features/calls/call_system_ui.dart';

class _Sent {
  _Sent(this.chatId, this.peerId, this.signal);
  final String chatId;
  final String peerId;
  final CallSignal signal;
}

class _FakeSignaling implements CallSignaling {
  final sent = <_Sent>[];
  Object? failWith;
  bool peerCanTake = true;
  Completer<void>? canTakeGate;
  final kinds = <String?>[];
  CallSignalEvent? invite;
  CallSignal? opened;
  bool fetchFails = false;

  @override
  Future<CallSignalEvent?> fetchInvite(String signalId) async {
    if (fetchFails) throw Exception('offline');
    final e = invite;
    invite = null; // once
    return e;
  }

  @override
  Future<CallSignal?> open(CallSignalEvent event, {DateTime? now}) async =>
      opened;

  @override
  Future<bool> peerCanTakeCalls({
    required String chatId,
    required String peerId,
  }) async {
    await canTakeGate?.future;
    return peerCanTake;
  }

  @override
  Future<void> send({
    required String chatId,
    required String peerId,
    required CallSignal signal,
    String? kind,
  }) async {
    if (failWith != null) throw failWith!;
    sent.add(_Sent(chatId, peerId, signal));
    kinds.add(kind);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeMedia implements CallMedia {
  CallAudioLevels levels = CallAudioLevels.silent;

  @override
  Future<CallAudioLevels> audioLevels() async => levels;

  final _status = StreamController<CallMediaStatus>.broadcast();
  Completer<String>? offerGate;
  String? acceptedOffer;
  String? preparedOffer;
  bool prepareFails = false;
  String? appliedAnswer;
  bool closed = false;
  bool muted = false;

  void emit(CallMediaStatus s) => _status.add(s);

  @override
  Future<String> createOffer() => offerGate?.future ?? Future.value('OFFER');

  @override
  Future<String> acceptOffer(String offerSdp) async {
    acceptedOffer = offerSdp;
    return 'ANSWER';
  }

  @override
  Future<void> prepareAnswer(String offerSdp) async {
    if (prepareFails) throw Exception('prepare failed');
    preparedOffer = offerSdp;
  }

  @override
  Future<void> applyAnswer(String answerSdp) async => appliedAnswer = answerSdp;

  int restartOffers = 0;
  bool restartFails = false;
  String? restartAnsweredOffer;

  @override
  Future<String> restartOffer() async {
    restartOffers++;
    if (restartFails) throw Exception('offline');
    return 'RESTART_OFFER_$restartOffers';
  }

  @override
  Future<String> answerRestart(String offerSdp) async {
    restartAnsweredOffer = offerSdp;
    return 'RESTART_ANSWER';
  }

  @override
  Stream<CallMediaStatus> get status => _status.stream;

  @override
  void setMuted(bool m) => muted = m;

  @override
  Future<void> setSpeaker(bool on) async {}

  @override
  Future<void> close() async => closed = true;
}

class _FakeSystemUi implements CallSystemUi {
  final ended = <String>[];
  @override
  Future<void> end(String signalId) async => ended.add(signalId);

  @override
  bool ringsInForeground = false;

  final showing = <String>{};
  @override
  Future<bool> isShowing(String signalId) async => showing.contains(signalId);
}

class _FakeLoader implements CallIceConfigLoader {
  CallIceConfig config = const CallIceConfig();
  Object? failWith;
  Completer<void>? gate;
  int loads = 0;

  @override
  Future<CallIceConfig> load({
    required String chatId,
    required String peerId,
  }) async {
    loads++;
    await gate?.future;
    if (failWith != null) throw failWith!;
    return config;
  }
}

class _FakeLogWriter implements CallLogWriter {
  final entries = <CallLogEntry>[];
  @override
  Future<void> write({
    required String chatId,
    required CallLogEntry entry,
    required DateTime at,
  }) async =>
      entries.add(entry);
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

class _FakeRinger implements CallRinger {
  bool ringback = false;
  @override
  void startRingback() => ringback = true;

  int endTones = 0;
  @override
  void playEndTone() => endTones++;

  bool ringing = false;
  @override
  void start() => ringing = true;
  @override
  void stop() {
    ringing = false;
    ringback = false;
  }
}

const _chat = 'chat-1';
const _peer = 'peer-1';

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Waits until [done] holds, at most [limit]. A fixed wait that fits the
/// restart timers on a quiet machine missed them under the full suite's load
/// (2026-10-23: 60 ms for a 20 ms timer, and once nothing had been sent yet).
Future<void> _until(
  bool Function() done, {
  Duration limit = const Duration(seconds: 2),
}) async {
  final end = DateTime.now().add(limit);
  while (!done() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late _FakeSignaling signaling;
  late List<_FakeMedia> medias;
  var factoryPrepareFails = false;
  late _FakeRinger ringer;
  late _FakeProximity proximity;
  late _FakeKeepAlive keepAlive;
  late _FakeLogWriter log;
  late _FakeLoader loader;
  late _FakeSystemUi systemUi;
  var foreground = true;
  late List<CallIceConfig> configs;
  late ProviderContainer c;
  Completer<String>? nextOfferGate;
  late CallRestartTiming restartTiming;

  CallController ctrl() => c.read(callControllerProvider.notifier);
  CallState st() => c.read(callControllerProvider);

  setUp(() {
    signaling = _FakeSignaling();
    medias = [];
    factoryPrepareFails = false;
    ringer = _FakeRinger();
    proximity = _FakeProximity();
    keepAlive = _FakeKeepAlive();
    log = _FakeLogWriter();
    loader = _FakeLoader();
    systemUi = _FakeSystemUi();
    foreground = true;
    configs = [];
    nextOfferGate = null;
    restartTiming = const CallRestartTiming(
      firstTry: Duration(milliseconds: 20),
      retry: Duration(milliseconds: 40),
      window: Duration(milliseconds: 400),
    );
    c = ProviderContainer(overrides: [
      eventBusProvider.overrideWithValue(null),
      callSignalingProvider.overrideWithValue(signaling),
      callIceConfigLoaderProvider.overrideWithValue(loader),
      callSystemUiProvider.overrideWithValue(systemUi),
      callAppInForegroundProvider.overrideWithValue(() => foreground),
      callMediaFactoryProvider.overrideWithValue((config) {
        configs.add(config);
        final m = _FakeMedia()
          ..offerGate = nextOfferGate
          ..prepareFails = factoryPrepareFails;
        medias.add(m);
        return m;
      }),
      callKeepAliveProvider.overrideWithValue(keepAlive),
      callLogWriterProvider.overrideWithValue(log),
      callProximityProvider.overrideWithValue(proximity),
      callRingerProvider.overrideWithValue(ringer),
      // Read lazily at the first interruption, so a test may set its own
      // before that.
      callRestartTimingProvider.overrideWith((ref) => restartTiming),
    ]);
    // Keep the notifier alive like the overlay does in the app.
    c.listen(callControllerProvider, (_, _) {});
  });

  tearDown(() => c.dispose());

  CallSignal invite(String id, {String sdp = 'REMOTE_OFFER'}) => CallSignal(
      type: CallSignalType.invite, callId: id, sentAt: DateTime.now(), sdp: sdp);

  group('Anrufen', () {
    test('wählen schickt das Angebot als Einladung an das Gegenüber', () async {
      await ctrl().dial(chatId: _chat, peerId: _peer);
      expect(st().phase, CallPhase.outgoing);
      expect(signaling.sent, hasLength(1));
      final s = signaling.sent.single;
      expect(s.peerId, _peer);
      expect(s.chatId, _chat);
      expect(s.signal.type, CallSignalType.invite);
      expect(s.signal.sdp, 'OFFER');
      expect(s.signal.callId, st().callId);
    });

    test('Annahme → Antwort landet bei WebRTC → verbunden → aktiv', () async {
      await ctrl().dial(chatId: _chat, peerId: _peer);
      final id = st().callId!;
      await ctrl().handleSignal(
        chatId: _chat,
        senderId: _peer,
        signal: CallSignal(
            type: CallSignalType.accept,
            callId: id,
            sentAt: DateTime.now(),
            sdp: 'REMOTE_ANSWER'),
      );
      expect(medias.single.appliedAnswer, 'REMOTE_ANSWER');
      expect(st().phase, CallPhase.connecting);

      medias.single.emit(CallMediaStatus.connected);
      await _settle();
      expect(st().phase, CallPhase.active);
    });

    test('auflegen meldet das Ende und gibt das Mikrofon frei', () async {
      await ctrl().dial(chatId: _chat, peerId: _peer);
      ctrl().hangUp();
      await _settle();
      expect(st().endReason, CallEndReason.cancelled);
      expect(signaling.sent.last.signal.type, CallSignalType.end);
      expect(signaling.sent.last.signal.reason, 'cancelled');
      expect(medias.single.closed, isTrue);
    });

    test('Auflegen, während das Mikrofon noch aufgeht: keine Einladung',
        () async {
      final gate = nextOfferGate = Completer<String>();
      final dialing = ctrl().dial(chatId: _chat, peerId: _peer);
      await _settle();
      ctrl().hangUp();
      gate.complete('LATE_OFFER');
      await dialing;
      await _settle();
      expect(signaling.sent.where((s) => s.signal.type == CallSignalType.invite),
          isEmpty);
      expect(st().phase, CallPhase.ended);
    });

    test('Gegenüber ohne signierten Schlüssel: klingelt nicht, sagt warum',
        () async {
      signaling.failWith = const CallPeerNotReady();
      await ctrl().dial(chatId: _chat, peerId: _peer);
      await _settle();
      expect(st().endReason, CallEndReason.unavailable);
      expect(medias.single.closed, isTrue);
    });

    test('geänderter Schlüssel: Anruf wird verweigert', () async {
      signaling.failWith = const CallPeerKeyMismatch();
      await ctrl().dial(chatId: _chat, peerId: _peer);
      expect(st().endReason, CallEndReason.keyChanged);
    });
  });

  group('Angerufen werden', () {
    test('Einladung klingelt; Annehmen beantwortet genau dieses Angebot',
        () async {
      await ctrl().handleSignal(
          chatId: _chat, senderId: _peer, signal: invite('c1'));
      expect(st().phase, CallPhase.incoming);
      expect(ringer.ringing, isTrue);

      await ctrl().accept();
      await _settle();
      expect(ringer.ringing, isFalse);
      expect(medias.single.acceptedOffer, 'REMOTE_OFFER');
      final s = signaling.sent.single;
      expect(s.signal.type, CallSignalType.accept);
      expect(s.signal.sdp, 'ANSWER');
      expect(s.signal.callId, 'c1');
      expect(s.peerId, _peer);
    });

    test('ablehnen öffnet kein Mikrofon', () async {
      await ctrl().handleSignal(
          chatId: _chat, senderId: _peer, signal: invite('c1'));
      ctrl().hangUp();
      await _settle();
      // A connection may have been warmed up while it rang, but the
      // microphone (acceptOffer) never opened, and it is closed again.
      expect(medias.where((m) => m.acceptedOffer != null), isEmpty);
      expect(medias.every((m) => m.closed), isTrue);
      expect(signaling.sent.single.signal.reason, 'declined');
      expect(ringer.ringing, isFalse);
    });

    test('zweiter Anrufer bekommt besetzt, das Angebot bleibt das erste',
        () async {
      await ctrl().handleSignal(
          chatId: _chat, senderId: _peer, signal: invite('c1'));
      await ctrl().handleSignal(
          chatId: 'chat-2',
          senderId: 'peer-2',
          signal: invite('c2', sdp: 'OTHER'));
      await _settle();
      expect(signaling.sent.single.peerId, 'peer-2');
      expect(signaling.sent.single.signal.reason, 'busy');

      await ctrl().accept();
      expect(medias.single.acceptedOffer, 'REMOTE_OFFER');
    });

    test('Ende für unseren Anruf von jemand anderem wird ignoriert', () async {
      await ctrl().handleSignal(
          chatId: _chat, senderId: _peer, signal: invite('c1'));
      await ctrl().handleSignal(
        chatId: _chat,
        senderId: 'eindringling',
        signal: CallSignal(
            type: CallSignalType.end,
            callId: 'c1',
            sentAt: DateTime.now(),
            reason: 'hangup'),
      );
      expect(st().phase, CallPhase.incoming);
    });

    test('Abbruch durch den Anrufer → verpasst, Klingeln hört auf', () async {
      await ctrl().handleSignal(
          chatId: _chat, senderId: _peer, signal: invite('c1'));
      await ctrl().handleSignal(
        chatId: _chat,
        senderId: _peer,
        signal: CallSignal(
            type: CallSignalType.end,
            callId: 'c1',
            sentAt: DateTime.now(),
            reason: 'cancelled'),
      );
      expect(st().endReason, CallEndReason.missed);
      expect(ringer.ringing, isFalse);
    });
  });

  test('stumm schalten erreicht die Tonspur', () async {
    await ctrl().dial(chatId: _chat, peerId: _peer);
    ctrl().toggleMute();
    expect(st().muted, isTrue);
    expect(medias.single.muted, isTrue);
  });

  group('Schneller verbinden', () {
    test('Prüfung und Konfiguration laufen gleichzeitig', () async {
      signaling.canTakeGate = Completer<void>();
      final dialing = ctrl().dial(chatId: _chat, peerId: _peer);
      await _settle();
      expect(loader.loads, 1,
          reason: 'die Konfiguration lädt schon, während die Prüfung läuft');
      signaling.canTakeGate!.complete();
      await dialing;
      expect(signaling.sent.single.signal.type, CallSignalType.invite);
    });

    test('kann keine Anrufe und kein Relay: es zählt „kann nicht“, nichts bleibt hängen',
        () async {
      signaling.peerCanTake = false;
      loader.failWith = const CallRelayUnavailable();
      await ctrl().dial(chatId: _chat, peerId: _peer);
      await _settle();
      expect(st().endReason, CallEndReason.unavailable);
      expect(medias, isEmpty);
    });

    test('die Konfiguration lädt schon beim Klingeln, Annehmen lädt nicht neu',
        () async {
      await ctrl().handleSignal(
          chatId: _chat, senderId: _peer, signal: invite('c1'));
      await _settle();
      expect(loader.loads, 1);
      expect(medias.single.acceptedOffer, isNull,
          reason: 'kein Mikrofon vor dem Annehmen');
      await ctrl().accept();
      await _settle();
      expect(loader.loads, 1);
      expect(signaling.sent.single.signal.type, CallSignalType.accept);
    });

    test('scheitert das Vorladen, versucht Annehmen es noch einmal', () async {
      loader.failWith = Exception('offline');
      await ctrl().handleSignal(
          chatId: _chat, senderId: _peer, signal: invite('c1'));
      await _settle();
      loader.failWith = null;
      await ctrl().accept();
      await _settle();
      expect(loader.loads, 2);
      expect(signaling.sent.single.signal.type, CallSignalType.accept);
    });

    test('abgelehnt: das Vorgeladene wird nicht für den nächsten Anruf benutzt',
        () async {
      await ctrl().handleSignal(
          chatId: _chat, senderId: _peer, signal: invite('c1'));
      await _settle();
      ctrl().hangUp();
      await _settle();
      ctrl().dismiss();
      await ctrl().handleSignal(
          chatId: _chat, senderId: _peer, signal: invite('c2'));
      await _settle();
      await ctrl().accept();
      await _settle();
      expect(loader.loads, 2, reason: 'jeder Anruf lädt seine eigene');
    });
  });

  group('Netzwechsel im Gespräch', () {
    Future<String> activeAsCaller() async {
      await ctrl().dial(chatId: _chat, peerId: _peer);
      final id = st().callId!;
      await ctrl().handleSignal(
        chatId: _chat,
        senderId: _peer,
        signal: CallSignal(
            type: CallSignalType.accept,
            callId: id,
            sentAt: DateTime.now(),
            sdp: 'REMOTE_ANSWER'),
      );
      medias.single.emit(CallMediaStatus.connected);
      await _settle();
      expect(st().phase, CallPhase.active);
      signaling.sent.clear();
      return id;
    }

    Future<String> activeAsCallee() async {
      await ctrl().handleSignal(
          chatId: _chat, senderId: _peer, signal: invite('c1'));
      await ctrl().accept();
      await _settle();
      medias.single.emit(CallMediaStatus.connected);
      await _settle();
      expect(st().phase, CallPhase.active);
      signaling.sent.clear();
      return 'c1';
    }

    CallSignal restart(String id, int seq, {String sdp = 'PEER_RESTART'}) =>
        CallSignal(
            type: CallSignalType.restart,
            callId: id,
            sentAt: DateTime.now(),
            sdp: sdp,
            seq: seq);

    test('Anrufer: unterbrochen → Hinweis, dann neue Runde mit frischem Angebot',
        () async {
      final id = await activeAsCaller();
      medias.single.emit(CallMediaStatus.interrupted);
      await _settle();
      expect(st().reconnecting, isTrue);
      await _until(() => signaling.sent.isNotEmpty);
      final s = signaling.sent.first.signal;
      expect(s.type, CallSignalType.restart);
      expect(s.callId, id);
      expect(s.seq, 1);
      expect(s.sdp, 'RESTART_OFFER_1');
    });

    test('kommt die Verbindung von selbst zurück, gibt es keine Runde', () async {
      await activeAsCaller();
      medias.single.emit(CallMediaStatus.interrupted);
      await _settle();
      medias.single.emit(CallMediaStatus.restored);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(st().reconnecting, isFalse);
      expect(signaling.sent, isEmpty);
      expect(medias.single.restartOffers, 0);
    });

    test('Antwort der passenden Runde wird angewendet, eine alte nicht', () async {
      // No second round in between: under the CI's load the 40 ms retry had
      // already started round 2 before the reply to round 1 arrived, and the
      // controller rightly dropped it as stale (pipeline #919).
      restartTiming = const CallRestartTiming(
        firstTry: Duration(milliseconds: 20),
        retry: Duration(seconds: 30),
        window: Duration(seconds: 60),
      );
      final id = await activeAsCaller();
      medias.single.emit(CallMediaStatus.interrupted);
      await _until(() => signaling.sent.isNotEmpty);
      CallSignal restarted(int seq) => CallSignal(
          type: CallSignalType.restarted,
          callId: id,
          sentAt: DateTime.now(),
          sdp: 'ANSWER_$seq',
          seq: seq);
      await ctrl().handleSignal(
          chatId: _chat, senderId: _peer, signal: restarted(7));
      expect(medias.single.appliedAnswer, 'REMOTE_ANSWER',
          reason: 'Runde 7 gab es nie');
      await ctrl().handleSignal(
          chatId: _chat, senderId: _peer, signal: restarted(1));
      expect(medias.single.appliedAnswer, 'ANSWER_1');
    });

    test('Angerufener beantwortet eine Runde, eine wiederholte nicht noch einmal',
        () async {
      final id = await activeAsCallee();
      await ctrl().handleSignal(
          chatId: _chat, senderId: _peer, signal: restart(id, 1));
      expect(medias.single.restartAnsweredOffer, 'PEER_RESTART');
      final s = signaling.sent.single.signal;
      expect(s.type, CallSignalType.restarted);
      expect(s.seq, 1);
      expect(s.sdp, 'RESTART_ANSWER');

      medias.single.restartAnsweredOffer = null;
      await ctrl().handleSignal(
          chatId: _chat, senderId: _peer, signal: restart(id, 1, sdp: 'REPLAY'));
      expect(medias.single.restartAnsweredOffer, isNull,
          reason: 'eine eingespielte alte Runde darf nichts umbauen');
      expect(signaling.sent, hasLength(1));
    });

    test('Angerufener startet selbst keine Runde', () async {
      await activeAsCallee();
      medias.single.emit(CallMediaStatus.interrupted);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(st().reconnecting, isTrue);
      expect(medias.single.restartOffers, 0);
    });

    test('„failed“ mitten im Gespräch beendet nicht sofort, erst nach dem Fenster',
        () async {
      await activeAsCaller();
      medias.single.emit(CallMediaStatus.failed);
      await _settle();
      expect(st().phase, CallPhase.active);
      expect(st().reconnecting, isTrue);
      await _until(() => st().phase == CallPhase.ended);
      expect(st().phase, CallPhase.ended);
      expect(st().endReason, CallEndReason.failed);
    });

    test('wieder da vor dem Fenster: der Anruf läuft weiter', () async {
      await activeAsCaller();
      medias.single.emit(CallMediaStatus.failed);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      medias.single.emit(CallMediaStatus.restored);
      await Future<void>.delayed(const Duration(milliseconds: 450));
      expect(st().phase, CallPhase.active);
      expect(st().reconnecting, isFalse);
    });

    test('Senden scheitert (offline): es wird weiter versucht', () async {
      await activeAsCaller();
      medias.single.restartFails = true;
      medias.single.emit(CallMediaStatus.interrupted);
      await _until(() => medias.single.restartOffers >= 2);
      expect(medias.single.restartOffers, greaterThanOrEqualTo(2));
    });

    test('vor dem ersten Verbinden endet „failed“ wie bisher sofort', () async {
      await ctrl().dial(chatId: _chat, peerId: _peer);
      await ctrl().handleSignal(
        chatId: _chat,
        senderId: _peer,
        signal: CallSignal(
            type: CallSignalType.accept,
            callId: st().callId!,
            sentAt: DateTime.now(),
            sdp: 'REMOTE_ANSWER'),
      );
      expect(st().phase, CallPhase.connecting);
      medias.single.emit(CallMediaStatus.failed);
      await _settle();
      expect(st().phase, CallPhase.ended);
    });
  });

  group('Vorwärmen beim Klingeln', () {
    test('die Verbindung entsteht beim Klingeln, ohne Mikrofon', () async {
      await ctrl().handleSignal(
          chatId: _chat, senderId: _peer, signal: invite('c1', sdp: 'OFFER_1'));
      await _settle();
      expect(medias, hasLength(1));
      expect(medias.single.preparedOffer, 'OFFER_1');
      expect(medias.single.acceptedOffer, isNull);
      expect(signaling.sent, isEmpty, reason: 'nichts geht raus vor dem Annehmen');
    });

    test('Annehmen benutzt genau diese Verbindung, keine zweite', () async {
      await ctrl().handleSignal(
          chatId: _chat, senderId: _peer, signal: invite('c1', sdp: 'OFFER_1'));
      await _settle();
      await ctrl().accept();
      await _settle();
      expect(medias, hasLength(1));
      expect(medias.single.acceptedOffer, 'OFFER_1');
      expect(signaling.sent.single.signal.type, CallSignalType.accept);
    });

    test('abgelehnt: die vorgewärmte Verbindung wird geschlossen', () async {
      await ctrl().handleSignal(
          chatId: _chat, senderId: _peer, signal: invite('c1'));
      await _settle();
      ctrl().hangUp();
      await _settle();
      expect(medias.single.closed, isTrue);
    });

    test('scheitert das Vorwärmen, wird trotzdem angenommen', () async {
      factoryPrepareFails = true;
      await ctrl().handleSignal(
          chatId: _chat, senderId: _peer, signal: invite('c1'));
      await _settle();
      await ctrl().accept();
      await _settle();
      expect(medias.first.acceptedOffer, isNotNull);
      expect(signaling.sent.single.signal.type, CallSignalType.accept);
    });

    test('sofort angenommen (Systemoberfläche): wartet auf das Vorwärmen statt doppelt zu bauen',
        () async {
      loader.gate = Completer<void>();
      await ctrl().handleSignal(
          chatId: _chat, senderId: _peer, signal: invite('c1'));
      final accepting = ctrl().accept();
      await _settle();
      loader.gate!.complete();
      await accepting;
      await _settle();
      expect(medias, hasLength(1));
      expect(signaling.sent.single.signal.type, CallSignalType.accept);
    });
  });

  group('Vermittlungsdienst', () {
    test('die geladene Konfiguration erreicht die Tonspur', () async {
      loader.config = const CallIceConfig(servers: [
        {
          'urls': ['turn:relay:3478'],
          'username': 'u',
          'credential': 'c'
        }
      ], relayOnly: true);
      await ctrl().dial(chatId: _chat, peerId: _peer);
      expect(configs.single.relayOnly, isTrue);
      expect(configs.single.servers.single['username'], 'u');
    });

    test('nur über den Server, aber keiner da: es klingelt nicht', () async {
      loader.failWith = const CallRelayUnavailable();
      await ctrl().dial(chatId: _chat, peerId: _peer);
      expect(st().phase, CallPhase.ended);
      expect(st().endReason, CallEndReason.relayUnavailable);
      expect(medias, isEmpty);
      expect(signaling.sent, isEmpty);
    });

    test('nur über den Server beim Annehmen: Gegenüber erfährt das Ende',
        () async {
      // Fails while it rings (prefetch) AND on the fresh try at accept.
      loader.failWith = const CallRelayUnavailable();
      await ctrl().handleSignal(
          chatId: _chat, senderId: _peer, signal: invite('c1'));
      await ctrl().accept();
      await _settle();
      expect(st().endReason, CallEndReason.relayUnavailable);
      expect(medias, isEmpty);
      final s = signaling.sent.single;
      expect(s.signal.type, CallSignalType.end);
      expect(s.signal.reason, 'failed');
    });

    test('aufgelegt, während die Konfiguration lädt: kein Mikrofon', () async {
      loader.gate = Completer<void>();
      final dialing = ctrl().dial(chatId: _chat, peerId: _peer);
      await _settle();
      ctrl().hangUp();
      loader.gate!.complete();
      await dialing;
      await _settle();
      expect(medias, isEmpty);
      expect(st().endReason, CallEndReason.cancelled);
    });
  });

  group('Wellenform', () {
    test('stumm zählt die eigene Stimme als Stille, das Gegenüber nicht',
        () async {
      await ctrl().handleSignal(
          chatId: _chat, senderId: _peer, signal: invite('c1'));
      await ctrl().accept();
      await _settle();
      medias.single
        ..emit(CallMediaStatus.connected)
        ..levels = const CallAudioLevels(local: 0.3, remote: 0.2);
      await _settle();
      expect((await ctrl().audioLevels()).local, 0.3);
      ctrl().toggleMute();
      final l = await ctrl().audioLevels();
      expect(l.local, 0);
      expect(l.remote, 0.2);
    });

    test('vor dem Verbinden gibt es nichts zu zeigen', () async {
      await ctrl().dial(chatId: _chat, peerId: _peer);
      medias.single.levels = const CallAudioLevels(local: 0.5, remote: 0.5);
      final l = await ctrl().audioLevels();
      expect(l.local, 0);
      expect(l.remote, 0);
    });
  });

  group('Töne', () {
    test('Auflegen spielt den Schluss-Ton genau einmal', () async {
      await ctrl().dial(chatId: _chat, peerId: _peer);
      expect(ringer.endTones, 0);
      ctrl().hangUp();
      await _settle();
      expect(st().phase, CallPhase.ended);
      expect(ringer.endTones, 1);
    });

    test('auch wenn das Gegenüber auflegt', () async {
      await ctrl().handleSignal(
          chatId: _chat, senderId: _peer, signal: invite('c1'));
      expect(ringer.ringing, isTrue);
      await ctrl().handleSignal(
          chatId: _chat,
          senderId: _peer,
          signal: CallSignal(
              type: CallSignalType.end,
              callId: 'c1',
              sentAt: DateTime.now(),
              reason: 'cancelled'));
      expect(ringer.ringing, isFalse);
      expect(ringer.endTones, 1);
    });
  });

  test('Gegenüber mit alter App: es klingelt gar nicht erst', () async {
    signaling.peerCanTake = false;
    await ctrl().dial(chatId: _chat, peerId: _peer);
    expect(st().phase, CallPhase.ended);
    expect(st().endReason, CallEndReason.unavailable);
    expect(medias, isEmpty);
    expect(signaling.sent, isEmpty);
  });

  test('der Anrufer hört einen Freiton, bis abgenommen wird', () async {
    await ctrl().dial(chatId: _chat, peerId: _peer);
    expect(ringer.ringback, isTrue);
    expect(ringer.ringing, isFalse, reason: 'no vibration for the caller');
    await ctrl().handleSignal(
        chatId: _chat,
        senderId: _peer,
        signal: CallSignal(
            type: CallSignalType.accept,
            callId: st().callId!,
            sentAt: DateTime.now(),
            sdp: 'ANSWER'));
    expect(ringer.ringback, isFalse);
  });

  group('Klingeln bei geschlossener App (Stufe 3)', () {
    test('der Server erfährt nur: dieses Signal klingelt / bricht ab',
        () async {
      await ctrl().dial(chatId: _chat, peerId: _peer);
      ctrl().hangUp();
      await _settle();
      expect(signaling.kinds, ['invite', 'cancel']);
    });

    test('Ablehnen ist kein Abbruch: es gibt nichts wegzuklingeln', () async {
      await ctrl().handleSignal(
          chatId: _chat, senderId: _peer, signal: invite('c1'));
      ctrl().hangUp();
      await _settle();
      expect(signaling.kinds, [null]);
    });

    test('Annehmen in der System-Oberfläche holt die Einladung und nimmt an',
        () async {
      signaling
        ..invite = CallSignalEvent(
            chatId: _chat, senderId: _peer, signalId: 's1', envelope: 'E')
        ..opened = invite('c1');
      await ctrl().acceptFromSystem('s1');
      await _settle();
      expect(st().phase, CallPhase.connecting);
      expect(medias.single.acceptedOffer, 'REMOTE_OFFER');
      expect(signaling.sent.single.signal.type, CallSignalType.accept);
      // The system UI keeps the call until it ends (iOS audio session).
      expect(systemUi.ended, isEmpty);
      ctrl().hangUp();
      await _settle();
      expect(systemUi.ended, ['s1']);
    });

    test('Ablehnen in der System-Oberfläche sagt dem Anrufer ab', () async {
      signaling
        ..invite = CallSignalEvent(
            chatId: _chat, senderId: _peer, signalId: 's1', envelope: 'E')
        ..opened = invite('c1');
      await ctrl().declineFromSystem('s1');
      await _settle();
      expect(medias.where((m) => m.acceptedOffer != null), isEmpty);
      expect(signaling.sent.single.signal.reason, 'declined');
    });

    test('zweites Annehmen derselben Einladung lässt das Gespräch stehen',
        () async {
      signaling
        ..invite = CallSignalEvent(
            chatId: _chat, senderId: _peer, signalId: 's1', envelope: 'E')
        ..opened = invite('c1');
      await ctrl().acceptFromSystem('s1');
      await _settle();
      signaling.invite = null; // fetched once, gone on the server
      await ctrl().acceptFromSystem('s1');
      await _settle();
      expect(st().phase, CallPhase.connecting);
      expect(systemUi.ended, isEmpty);
    });

    test('Auflegen in der System-Oberfläche beendet das Gespräch', () async {
      signaling
        ..invite = CallSignalEvent(
            chatId: _chat, senderId: _peer, signalId: 's1', envelope: 'E')
        ..opened = invite('c1');
      await ctrl().acceptFromSystem('s1');
      await _settle();
      ctrl().endFromSystem('other');
      expect(st().phase, CallPhase.connecting, reason: 'not our call');
      ctrl().endFromSystem('s1');
      await _settle();
      expect(st().phase, CallPhase.ended);
      expect(signaling.sent.last.signal.type, CallSignalType.end);
    });

    test('Auflegen in der Benachrichtigung beendet das Gespräch', () async {
      await ctrl().dial(chatId: _chat, peerId: _peer);
      keepAlive.hangUps.add(null);
      await _settle();
      expect(st().phase, CallPhase.ended);
    });

    test('Abholen scheitert: System-Anruf verschwindet statt zu hängen',
        () async {
      signaling.fetchFails = true;
      await ctrl().acceptFromSystem('s1');
      await _settle();
      expect(st().phase, CallPhase.idle);
      expect(systemUi.ended, ['s1']);
    });

    test('Einladung schon weg: System-Anruf verschwindet, nichts klingelt',
        () async {
      await ctrl().acceptFromSystem('s-alt');
      await _settle();
      expect(st().phase, CallPhase.idle);
      expect(systemUi.ended, ['s-alt']);
      expect(medias, isEmpty);
    });

    test('in der App angenommen: die System-Oberfläche verschwindet sofort',
        () async {
      await ctrl().handleSignal(
          chatId: _chat,
          senderId: _peer,
          signal: invite('c1'),
          signalId: 's1');
      await ctrl().accept();
      await _settle();
      expect(systemUi.ended, ['s1']);
    });

    test('im Hintergrund klingelt nur das System, nicht die App', () async {
      foreground = false;
      await ctrl().handleSignal(
          chatId: _chat, senderId: _peer, signal: invite('c1'));
      expect(st().phase, CallPhase.incoming);
      expect(ringer.ringing, isFalse);
    });

    test('iOS: klingelt CallKit schon, schweigt die App', () async {
      systemUi.ringsInForeground = true;
      systemUi.showing.add('s1');
      await ctrl().handleSignal(
          chatId: _chat, senderId: _peer, signal: invite('c1'), signalId: 's1');
      await Future<void>.delayed(const Duration(milliseconds: 1700));
      expect(st().phase, CallPhase.incoming);
      expect(ringer.ringing, isFalse);
    });

    test('iOS: ohne CallKit-Anruf klingelt die App selbst', () async {
      systemUi.ringsInForeground = true;
      await ctrl().handleSignal(
          chatId: _chat, senderId: _peer, signal: invite('c1'), signalId: 's1');
      expect(ringer.ringing, isFalse, reason: 'waits for CallKit first');
      await Future<void>.delayed(const Duration(milliseconds: 1700));
      expect(ringer.ringing, isTrue);
    });
  });

  group('Bildschirm am Ohr', () {
    test('während des Gesprächs an, mit Lautsprecher aus, danach aus',
        () async {
      await ctrl().dial(chatId: _chat, peerId: _peer);
      expect(proximity.active, isTrue, reason: 'calling, phone at the ear');
      ctrl().toggleSpeaker();
      expect(proximity.active, isFalse, reason: 'speaker: phone in front');
      ctrl().toggleSpeaker();
      expect(proximity.active, isTrue);
      ctrl().hangUp();
      await _settle();
      expect(proximity.active, isFalse);
    });

    test('beim Klingeln nicht – Annehmen muss sichtbar bleiben', () async {
      await ctrl().handleSignal(
          chatId: _chat, senderId: _peer, signal: invite('c1'));
      expect(proximity.active, isFalse);
      await ctrl().accept();
      expect(proximity.active, isTrue);
    });
  });

  group('Gespräch im Hintergrund (Android)', () {
    test('läuft weiter, solange der Anruf läuft – auch mit Lautsprecher',
        () async {
      await ctrl().dial(chatId: _chat, peerId: _peer);
      expect(keepAlive.active, isTrue);
      ctrl().toggleSpeaker();
      expect(keepAlive.active, isTrue, reason: 'speaker is still a call');
      ctrl().hangUp();
      await _settle();
      expect(keepAlive.active, isFalse);
    });

    test('nicht schon beim Klingeln, erst ab dem Annehmen', () async {
      await ctrl().handleSignal(
          chatId: _chat, senderId: _peer, signal: invite('c1'));
      expect(keepAlive.active, isFalse);
      await ctrl().accept();
      expect(keepAlive.active, isTrue);
    });
  });

  group('Einträge im Chat', () {
    test('ausgehend, nicht angenommen', () async {
      await ctrl().dial(chatId: _chat, peerId: _peer);
      ctrl().hangUp();
      await _settle();
      expect(log.entries.single.action, callOutgoing);
      expect(log.entries.single.detail, '0');
    });

    test('eingehend, selbst abgelehnt', () async {
      await ctrl().handleSignal(
          chatId: _chat, senderId: _peer, signal: invite('c1'));
      ctrl().hangUp();
      await _settle();
      expect(log.entries.single.action, callDeclined);
    });

    test('eingehend, Anrufer gibt auf: verpasst', () async {
      await ctrl().handleSignal(
          chatId: _chat, senderId: _peer, signal: invite('c1'));
      await ctrl().handleSignal(
          chatId: _chat,
          senderId: _peer,
          signal: CallSignal(
              type: CallSignalType.end,
              callId: 'c1',
              sentAt: DateTime.now(),
              reason: 'cancelled'));
      await _settle();
      expect(log.entries.single.action, callMissed);
    });

    test('gesprochen: eingehend mit Dauer', () async {
      await ctrl().handleSignal(
          chatId: _chat, senderId: _peer, signal: invite('c1'));
      await ctrl().accept();
      await _settle();
      medias.single.emit(CallMediaStatus.connected);
      await _settle();
      ctrl().hangUp();
      await _settle();
      expect(log.entries.single.action, callIncoming);
      expect(int.parse(log.entries.single.detail), greaterThanOrEqualTo(0));
    });

    test('nie geklingelt (Gegenüber kann keine Anrufe): kein Eintrag',
        () async {
      signaling.peerCanTake = false;
      await ctrl().dial(chatId: _chat, peerId: _peer);
      await _settle();
      expect(log.entries, isEmpty);
    });
  });

  group('Runterlegen', () {
    bool minimized() => c.read(callMinimizedProvider);
    CallMinimizedNotifier bar() => c.read(callMinimizedProvider.notifier);

    test('ohne Anruf lässt sich nichts verkleinern, mit Anruf schon', () async {
      c.listen(callMinimizedProvider, (_, _) {});
      bar().minimize();
      expect(minimized(), isFalse, reason: 'no call');

      await ctrl().handleSignal(
          chatId: _chat, senderId: _peer, signal: invite('c1'));
      await ctrl().accept();
      await _settle();
      bar().minimize();
      expect(minimized(), isTrue);
      expect(st().phase, isNot(CallPhase.ended),
          reason: 'shrinking never touches the call');

      bar().expand();
      expect(minimized(), isFalse);
    });

    test('ein klingelnder Anruf lässt sich verkleinern und bleibt es beim Annehmen',
        () async {
      // Gerry, 2026-10-24: Bisher musste man erst annehmen oder ablehnen.
      c.listen(callMinimizedProvider, (_, _) {});
      await ctrl().handleSignal(
          chatId: _chat, senderId: _peer, signal: invite('c1'));
      bar().minimize();
      expect(minimized(), isTrue);
      expect(st().phase, CallPhase.incoming, reason: 'es klingelt weiter');

      await ctrl().accept();
      await _settle();
      expect(minimized(), isTrue,
          reason: 'nach dem Annehmen wird es die grüne Leiste, kein Vollbild');
    });

    test('abgelehnt aus der Leiste: der nächste Anruf beginnt wieder groß',
        () async {
      c.listen(callMinimizedProvider, (_, _) {});
      await ctrl().handleSignal(
          chatId: _chat, senderId: _peer, signal: invite('c1'));
      bar().minimize();
      ctrl().hangUp();
      ctrl().dismiss();
      await _settle();
      expect(minimized(), isFalse);

      await ctrl().handleSignal(
          chatId: _chat, senderId: _peer, signal: invite('c2'));
      expect(st().phase, CallPhase.incoming);
      expect(minimized(), isFalse);
    });

    test('ein neuer Anruf beginnt wieder groß', () async {
      c.listen(callMinimizedProvider, (_, _) {});
      await ctrl().dial(chatId: _chat, peerId: _peer);
      bar().minimize();
      expect(minimized(), isTrue);

      ctrl().hangUp();
      ctrl().dismiss();
      await _settle();
      expect(st().phase, CallPhase.idle);
      expect(minimized(), isFalse);
    });
  });
}
