// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Two real WebRtcCallMedia in one process, wired back to back: the caller's
// complete offer goes to the callee, the callee's complete answer back. Both
// must report `connected` — with real libwebrtc, a real microphone and no
// STUN server, i.e. exactly the non-trickle, host-candidates-only path stage 1
// ships. Run on a desktop:
//   flutter test integration_test/call_media_loopback_test.dart -d linux
//
// The relay case (stage 2) needs a live coturn and fresh credentials, so it
// only runs when they are passed in — the RTCConfiguration list as JSON:
//   --dart-define=CALL_TEST_ICE='[{"urls":["turn:turn.chattr.at:3478"],…}]'

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:chattr/features/calls/call_media.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Anrufer und Angerufener verbinden sich ohne STUN', (_) async {
    final caller = WebRtcCallMedia(const CallIceConfig());
    final callee = WebRtcCallMedia(const CallIceConfig());
    try {
      final callerUp = caller.status.firstWhere((s) => s == CallMediaStatus.connected);
      final calleeUp = callee.status.firstWhere((s) => s == CallMediaStatus.connected);

      final offer = await caller.createOffer();
      expect(offer, contains('a=fingerprint:'), reason: 'DTLS fingerprint');
      expect(offer, contains('a=candidate:'),
          reason: 'candidates must be inlined (no trickle)');
      expect(offer, isNot(contains('m=video')));

      final answer = await callee.acceptOffer(offer);
      expect(answer, contains('a=candidate:'));
      await caller.applyAnswer(answer);

      await Future.wait([callerUp, calleeUp])
          .timeout(const Duration(seconds: 20));

      caller.setMuted(true);
      caller.setMuted(false);
    } finally {
      await caller.close();
      await callee.close();
      // Closing twice must be harmless (every way out releases).
      await caller.close();
    }
  });

  String? ufrag(String sdp) =>
      RegExp(r'a=ice-ufrag:(\S+)').firstMatch(sdp)?.group(1);

  testWidgets('vorgewärmt beim Klingeln: Antwort trägt den Stream und verbindet',
      (_) async {
    final caller = WebRtcCallMedia(const CallIceConfig());
    final callee = WebRtcCallMedia(const CallIceConfig());
    try {
      final callerUp = caller.status.firstWhere((s) => s == CallMediaStatus.connected);
      final calleeUp = callee.status.firstWhere((s) => s == CallMediaStatus.connected);

      final offer = await caller.createOffer();
      // Ringing: connection built, offer applied, microphone still closed.
      await callee.prepareAnswer(offer);
      // Accept: microphone in, answer out.
      final answer = await callee.acceptOffer(offer);
      // The web plays a remote track only when it comes with a stream: the
      // microphone added after the offer must still carry a stream id.
      final msid = RegExp(r'a=msid:(\S+) ').firstMatch(answer)?.group(1);
      expect(msid, isNotNull, reason: 'answer must carry a=msid');
      expect(msid, isNot('-'), reason: 'a stream id, not the empty "-"');
      expect(answer, contains('a=sendrecv'),
          reason: 'the receive-only transceiver must turn into send+receive');
      await caller.applyAnswer(answer);

      await Future.wait([callerUp, calleeUp])
          .timeout(const Duration(seconds: 20));
    } finally {
      await caller.close();
      await callee.close();
    }
  });

  testWidgets('Neustart mitten im Gespräch: neue Zugangsdaten, Verbindung bleibt',
      (_) async {
    final caller = WebRtcCallMedia(const CallIceConfig());
    final callee = WebRtcCallMedia(const CallIceConfig());
    final seen = <CallMediaStatus>[];
    try {
      caller.status.listen(seen.add);
      final callerUp = caller.status.firstWhere((s) => s == CallMediaStatus.connected);
      final calleeUp = callee.status.firstWhere((s) => s == CallMediaStatus.connected);
      final offer = await caller.createOffer();
      final answer = await callee.acceptOffer(offer);
      await caller.applyAnswer(answer);
      await Future.wait([callerUp, calleeUp])
          .timeout(const Duration(seconds: 20));

      final again = await caller.restartOffer();
      expect(ufrag(again), isNotNull);
      expect(ufrag(again), isNot(ufrag(offer)),
          reason: 'an ICE restart must bring new credentials');
      final reply = await callee.answerRestart(again);
      expect(ufrag(reply), isNot(ufrag(answer)));
      await caller.applyAnswer(reply);

      await Future<void>.delayed(const Duration(seconds: 4));
      expect(seen, isNot(contains(CallMediaStatus.failed)));
    } finally {
      await caller.close();
      await callee.close();
    }
  });

  const iceJson = String.fromEnvironment('CALL_TEST_ICE');
  testWidgets('nur über den Vermittlungsdienst: keine eigene Adresse im SDP',
      (_) async {
    final servers = [
      for (final e in jsonDecode(iceJson) as List<dynamic>)
        Map<String, dynamic>.from(e as Map)
    ];
    final config = CallIceConfig(servers: servers, relayOnly: true);
    final caller = WebRtcCallMedia(config);
    final callee = WebRtcCallMedia(config);
    try {
      final callerUp = caller.status.firstWhere((s) => s == CallMediaStatus.connected);
      final calleeUp = callee.status.firstWhere((s) => s == CallMediaStatus.connected);

      final offer = await caller.createOffer();
      final candidates =
          offer.split('\n').where((l) => l.startsWith('a=candidate:')).toList();
      expect(candidates, isNotEmpty, reason: 'TURN allocation must arrive');
      expect(candidates.every((l) => l.contains(' typ relay')), isTrue,
          reason: 'relay-only must not reveal host or srflx addresses');

      final answer = await callee.acceptOffer(offer);
      expect(
          answer
              .split('\n')
              .where((l) => l.startsWith('a=candidate:'))
              .every((l) => l.contains(' typ relay')),
          isTrue);
      await caller.applyAnswer(answer);

      await Future.wait([callerUp, calleeUp])
          .timeout(const Duration(seconds: 20));
    } finally {
      await caller.close();
      await callee.close();
    }
  }, skip: iceJson.isEmpty);
}
