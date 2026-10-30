// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Call setup used to wait for WebRTC's "gathering complete", which only comes
// once every interface has heard from every server: up to 6 s through the
// relay, before the invite AND again after "accept". These tests pin the rule
// that replaced it: send once one usable candidate is there, plus a short
// grace for the rest of the batch.

import 'package:chattr/features/calls/call_gathering.dart';
import 'package:flutter_test/flutter_test.dart';

const _relay =
    'candidate:1 1 udp 41885439 203.0.113.7 49170 typ relay raddr 0.0.0.0 rport 0';
const _relayTcp =
    'candidate:2 1 tcp 25108223 203.0.113.7 49171 typ relay raddr 0.0.0.0 rport 0 tcptype passive';
const _srflx =
    'candidate:3 1 udp 1686052607 198.51.100.4 51234 typ srflx raddr 192.168.1.20 rport 51234';
const _host = 'candidate:4 1 udp 2122260223 192.168.1.20 51234 typ host';

GatheringWatch _watch({bool relayOnly = true}) => GatheringWatch(
      relayOnly: relayOnly,
      timeout: const Duration(milliseconds: 400),
      grace: const Duration(milliseconds: 40),
    );

void main() {
  group('isUsableCandidate', () {
    test('nur über den Server: allein ein Relay-Kandidat zählt', () {
      expect(isUsableCandidate(_relay, relayOnly: true), isTrue);
      expect(isUsableCandidate(_relayTcp, relayOnly: true), isTrue);
      expect(isUsableCandidate(_srflx, relayOnly: true), isFalse);
      expect(isUsableCandidate(_host, relayOnly: true), isFalse);
    });

    test('direkt: Relay oder öffentliche Adresse, nie nur das eigene Netz', () {
      expect(isUsableCandidate(_relay, relayOnly: false), isTrue);
      expect(isUsableCandidate(_srflx, relayOnly: false), isTrue);
      expect(isUsableCandidate(_host, relayOnly: false), isFalse);
      expect(isUsableCandidate(null, relayOnly: false), isFalse);
      expect(isUsableCandidate('', relayOnly: false), isFalse);
    });

    test('im SDP wird die a=candidate-Zeile erkannt', () {
      const sdp = 'v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n'
          'a=candidate:4 1 udp 2122260223 192.168.1.20 51234 typ host\r\n';
      expect(sdpHasUsableCandidate(sdp, relayOnly: false), isFalse);
      expect(
          sdpHasUsableCandidate('${sdp}a=$_relay\r\n', relayOnly: true), isTrue);
    });
  });

  group('GatheringWatch', () {
    test('schickt kurz nach dem ersten brauchbaren Kandidaten', () async {
      final w = _watch();
      w.onCandidate(_relay);
      final clock = Stopwatch()..start();
      expect(await w.done, GatheringOutcome.enough);
      expect(clock.elapsedMilliseconds, lessThan(300),
          reason: 'nicht bis zur Obergrenze warten');
      expect(w.firstUsableAt, isNotNull);
    });

    test('was in der Nachfrist kommt, wird mitgezählt', () async {
      final w = _watch();
      w.onCandidate(_relay);
      w.onCandidate(_relayTcp);
      await w.done;
      expect(w.types['relay'], 2);
    });

    test('„fertig" von WebRTC beendet sofort', () async {
      final w = _watch();
      w.onCandidate(_host);
      w.onComplete();
      expect(await w.done, GatheringOutcome.complete);
    });

    test('ohne brauchbaren Kandidaten bis zur Obergrenze', () async {
      final w = _watch();
      w.onCandidate(_host);
      w.onCandidate(_srflx); // with relay-only this is not enough
      expect(await w.done, GatheringOutcome.timeout);
      expect(w.firstUsableAt, isNull);
    });

    test('direkt reicht eine öffentliche Adresse', () async {
      final w = _watch(relayOnly: false);
      w.onCandidate(_host);
      w.onCandidate(_srflx);
      expect(await w.done, GatheringOutcome.enough);
    });

    test('die Zusammenfassung nennt Zahlen und Typen, keine Adressen', () async {
      final w = _watch();
      w.onCandidate(_relay);
      final line = w.summary(await w.done);
      expect(line, contains('ICE enough'));
      expect(line, contains('relay 1'));
      expect(line, isNot(contains('203.0.113.7')));
    });
  });
}
