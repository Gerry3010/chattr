// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Two parties racing each other over a broadcast channel: invites cross,
// hangups overtake accepts, signals arrive twice or for a call that is long
// over. The property worth pinning down is that every such race ends in a
// defined state, and that the peer is told exactly once.

import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/features/calls/call_rules.dart';

const _chat = 'chat-1';
const _peer = 'peer-1';

CallState _run(List<CallEvent> events, [CallState s = CallState.idle]) {
  for (final e in events) {
    s = reduceCall(s, e).state;
  }
  return s;
}

const _dial = LocalDial(callId: 'c1', chatId: _chat, peerId: _peer);
const _invite = RemoteInvite(callId: 'c1', chatId: _chat, peerId: _peer);

void main() {
  group('Abgehender Anruf', () {
    test('wählen → angenommen → verbunden → aufgelegt', () {
      var s = _run([_dial]);
      expect(s.phase, CallPhase.outgoing);
      s = _run([const RemoteAccept('c1')], s);
      expect(s.phase, CallPhase.connecting);
      final at = DateTime.utc(2026, 10, 3, 1);
      s = _run([MediaConnected(at)], s);
      expect(s.phase, CallPhase.active);
      expect(s.connectedAt, at);

      final t = reduceCall(s, const LocalHangup());
      expect(t.state.phase, CallPhase.ended);
      expect(t.state.endReason, CallEndReason.hangup);
      expect(t.effects, [
        const SendEnd(
            callId: 'c1',
            peerId: _peer,
            chatId: _chat,
            reason: CallEndReason.hangup),
        const ReleaseMedia(),
      ]);
    });

    test('vor dem Abheben auflegen heißt abbrechen, beim Gegenüber verpasst',
        () {
      final t = reduceCall(_run([_dial]), const LocalHangup());
      expect(t.state.endReason, CallEndReason.cancelled);
      expect((t.effects.first as SendEnd).reason.wire, 'cancelled');

      final callee = _run([_invite, const RemoteEnd('c1', 'cancelled')]);
      expect(callee.endReason, CallEndReason.missed);
    });

    test('niemand hebt ab → keine Antwort, Gegenüber wird verständigt', () {
      final t = reduceCall(_run([_dial]), const RingTimeout('c1'));
      expect(t.state.endReason, CallEndReason.noAnswer);
      expect(t.effects.whereType<SendEnd>(), hasLength(1));
    });

    test('scheitert das Wählen vor dem Versand, erfährt das Gegenüber nichts',
        () {
      final t = reduceCall(
          _run([_dial]), const DialFailed(CallEndReason.unavailable));
      expect(t.state.endReason, CallEndReason.unavailable);
      expect(t.effects, [const ReleaseMedia()]);
    });

    test('Annahme für einen fremden Anruf wird ignoriert', () {
      final s = _run([_dial, const RemoteAccept('anderer')]);
      expect(s.phase, CallPhase.outgoing);
    });

    test('ein zweites Wählen während eines Anrufs tut nichts', () {
      final s = _run([
        _dial,
        const LocalDial(callId: 'c2', chatId: _chat, peerId: 'p2'),
      ]);
      expect(s.callId, 'c1');
    });

    test('nach dem Ende darf neu gewählt werden, ohne erst wegzuklicken', () {
      final s = _run([
        _dial,
        const LocalHangup(),
        const LocalDial(callId: 'c2', chatId: _chat, peerId: _peer),
      ]);
      expect(s.phase, CallPhase.outgoing);
      expect(s.callId, 'c2');
    });
  });

  group('Ankommender Anruf', () {
    test('ablehnen schickt declined und gibt das Mikrofon frei', () {
      final t = reduceCall(_run([_invite]), const LocalHangup());
      expect(t.state.endReason, CallEndReason.declined);
      expect(t.effects, contains(const ReleaseMedia()));
      expect((t.effects.first as SendEnd).reason, CallEndReason.declined);
    });

    test('Klingeln läuft aus → verpasst, ohne dem Anrufer etwas zu senden',
        () {
      final t = reduceCall(_run([_invite]), const RingTimeout('c1'));
      expect(t.state.endReason, CallEndReason.missed);
      expect(t.effects.whereType<SendEnd>(), isEmpty);
    });

    test('doppelt zugestellte Einladung ändert nichts', () {
      final s = _run([_invite, const LocalAccept(), _invite]);
      expect(s.phase, CallPhase.connecting);
    });

    test('zweiter Anrufer bekommt besetzt, der laufende Anruf bleibt', () {
      final s = _run([_invite, const LocalAccept()]);
      final t = reduceCall(
          s, const RemoteInvite(callId: 'c2', chatId: 'x', peerId: 'p2'));
      expect(t.state.callId, 'c1');
      expect(t.state.phase, CallPhase.connecting);
      expect(t.effects, [
        const SendEnd(
            callId: 'c2', peerId: 'p2', chatId: 'x', reason: CallEndReason.busy),
      ]);
    });

    test('Anrufer erfährt besetzt', () {
      final s = _run([_dial, const RemoteEnd('c1', 'busy')]);
      expect(s.endReason, CallEndReason.busy);
    });
  });

  group('Wettläufe und Nachzügler', () {
    test('Gegenüber legt auf → kein Echo zurück', () {
      final t = reduceCall(
          _run([_dial, const RemoteAccept('c1')]), const RemoteEnd('c1', 'hangup'));
      expect(t.state.endReason, CallEndReason.remoteHangup);
      expect(t.effects.whereType<SendEnd>(), isEmpty);
      expect(t.effects, contains(const ReleaseMedia()));
    });

    test('Ende für einen längst beendeten Anruf wird ignoriert', () {
      final s = _run([_dial, const LocalHangup()]);
      final t = reduceCall(s, const RemoteEnd('c1', 'hangup'));
      expect(t.state.endReason, CallEndReason.cancelled);
      expect(t.effects, isEmpty);
    });

    test('Medien kommen nach Annahme nie hoch → gescheitert', () {
      final t = reduceCall(_run([_invite, const LocalAccept()]),
          const RingTimeout('c1'));
      expect(t.state.endReason, CallEndReason.failed);
      expect(t.effects.whereType<SendEnd>(), hasLength(1));
    });

    test('Timeout eines laufenden Gesprächs beendet es nicht', () {
      final s = _run([
        _dial,
        const RemoteAccept('c1'),
        MediaConnected(DateTime.utc(2026)),
        const RingTimeout('c1'),
      ]);
      expect(s.phase, CallPhase.active);
    });

    test('Verbindungsabbruch im Gespräch → gescheitert und gemeldet', () {
      final t = reduceCall(
          _run([_dial, const RemoteAccept('c1'), MediaConnected(DateTime.utc(2026))]),
          const MediaFailed());
      expect(t.state.endReason, CallEndReason.failed);
      expect(t.effects.whereType<SendEnd>(), hasLength(1));
    });

    test('Wegklicken führt nur vom Ende zurück in den Ruhezustand', () {
      expect(_run([_dial, const Dismiss()]).phase, CallPhase.outgoing);
      expect(_run([_dial, const LocalHangup(), const Dismiss()]).isIdle, isTrue);
    });

    test('unbekannter Grund vom Draht gilt als aufgelegt', () {
      expect(endReasonFromWire('quatsch', wasIncoming: false),
          CallEndReason.remoteHangup);
    });
  });
}
