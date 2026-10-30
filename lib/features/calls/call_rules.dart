// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

/// The rule behind a call: which phase it is in, and what a signal or a tap
/// does to it.
///
/// Pure, like `unread_rules.dart` and `reaction_usage_rules.dart`. A call has
/// two parties racing each other over an unreliable channel — an invite can
/// arrive while we are dialing, a hangup can overtake the accept — and those
/// races are exactly what nobody checks if they can only be observed through
/// two phones and a microphone.
library;

/// Where a call stands, seen from this device.
enum CallPhase {
  /// No call.
  idle,

  /// We dialed; the peer's phone rings.
  outgoing,

  /// The peer dialed; ours rings.
  incoming,

  /// Both said yes; ICE/DTLS is still negotiating.
  connecting,

  /// Audio flows.
  active,

  /// Over. The screen shows why until it is dismissed.
  ended,
}

/// Why a call ended. Some of these also travel over the wire (see
/// [CallEndReason.wire]); the rest only describe what this device saw.
enum CallEndReason {
  /// We hung up an established (or connecting) call.
  hangup,

  /// The peer hung up an established (or connecting) call.
  remoteHangup,

  /// The callee said no.
  declined,

  /// The callee was already in another call.
  busy,

  /// We gave up dialing before anyone answered.
  cancelled,

  /// Nobody answered within [ringTimeout].
  noAnswer,

  /// An incoming call stopped ringing without us answering it.
  missed,

  /// The media path never came up, or broke down.
  failed,

  /// We could not even ring: the peer's app can't take calls yet (no signed
  /// chat key). Local only — nothing was sent.
  unavailable,

  /// We refused to ring: the peer's chat key doesn't match the identity we
  /// pinned for them. Local only.
  keyChanged,

  /// No microphone access. Local only.
  micDenied,

  /// The user asked for every call to go through our relay, and no relay was
  /// available. Connecting directly instead would hand the peer the very IP
  /// address the setting exists to hide, so the call ends. Local only.
  relayUnavailable;

  /// The word sent to the peer, so its screen can say the same thing.
  String get wire => switch (this) {
        hangup || remoteHangup => 'hangup',
        declined => 'declined',
        busy => 'busy',
        cancelled => 'cancelled',
        noAnswer => 'no_answer',
        missed => 'cancelled',
        failed ||
        unavailable ||
        keyChanged ||
        micDenied ||
        relayUnavailable =>
          'failed',
      };
}

/// How long a call rings before it is given up — on both sides, so a caller
/// that dies mid-ring doesn't leave the callee ringing forever.
const Duration ringTimeout = Duration(seconds: 45);

/// One call as this device sees it. Immutable; [reduceCall] makes new ones.
class CallState {
  const CallState({
    this.phase = CallPhase.idle,
    this.callId,
    this.chatId,
    this.peerId,
    this.connectedAt,
    this.endReason,
    this.muted = false,
    this.speakerOn = false,
    this.reconnecting = false,
  });

  final CallPhase phase;
  final String? callId;
  final String? chatId;
  final String? peerId;

  /// When audio started flowing; drives the call timer.
  final DateTime? connectedAt;
  final CallEndReason? endReason;
  final bool muted;
  final bool speakerOn;

  /// The connection dropped mid-call and is being rebuilt (network change,
  /// see the ICE restart in the controller). The call screen says so instead
  /// of leaving the user in silence.
  final bool reconnecting;

  static const idle = CallState();

  bool get isIdle => phase == CallPhase.idle;

  /// Anything between dialing/ringing and the end screen. A second call is
  /// turned away as busy while this is true.
  bool get isBusy =>
      phase != CallPhase.idle && phase != CallPhase.ended;

  CallState copyWith({
    CallPhase? phase,
    DateTime? connectedAt,
    CallEndReason? endReason,
    bool? muted,
    bool? speakerOn,
    bool? reconnecting,
  }) =>
      CallState(
        phase: phase ?? this.phase,
        callId: callId,
        chatId: chatId,
        peerId: peerId,
        connectedAt: connectedAt ?? this.connectedAt,
        endReason: endReason ?? this.endReason,
        muted: muted ?? this.muted,
        speakerOn: speakerOn ?? this.speakerOn,
        reconnecting: reconnecting ?? this.reconnecting,
      );

  @override
  String toString() => 'CallState($phase, $callId, peer=$peerId, '
      'end=$endReason)';
}

/// Something that happened to a call — a tap here, a signal from there, or a
/// timer.
sealed class CallEvent {
  const CallEvent();
}

class LocalDial extends CallEvent {
  const LocalDial({
    required this.callId,
    required this.chatId,
    required this.peerId,
  });
  final String callId;
  final String chatId;
  final String peerId;
}

class RemoteInvite extends CallEvent {
  const RemoteInvite({
    required this.callId,
    required this.chatId,
    required this.peerId,
  });
  final String callId;
  final String chatId;
  final String peerId;
}

/// Dialing failed before the invite went out — nothing to tell the peer.
class DialFailed extends CallEvent {
  const DialFailed(this.reason);
  final CallEndReason reason;
}

class LocalAccept extends CallEvent {
  const LocalAccept();
}

class RemoteAccept extends CallEvent {
  const RemoteAccept(this.callId);
  final String callId;
}

class MediaConnected extends CallEvent {
  const MediaConnected(this.at);
  final DateTime at;
}

/// The connection dropped during the call (ICE `disconnected`).
class MediaInterrupted extends CallEvent {
  const MediaInterrupted();
}

/// The connection is back after an interruption.
class MediaRestored extends CallEvent {
  const MediaRestored();
}

class MediaFailed extends CallEvent {
  const MediaFailed([this.reason = CallEndReason.failed]);
  final CallEndReason reason;
}

class LocalHangup extends CallEvent {
  const LocalHangup();
}

class RemoteEnd extends CallEvent {
  const RemoteEnd(this.callId, this.wireReason);
  final String callId;
  final String wireReason;
}

class RingTimeout extends CallEvent {
  const RingTimeout(this.callId);
  final String callId;
}

class Dismiss extends CallEvent {
  const Dismiss();
}

/// What the controller has to DO because of a transition. The reducer decides,
/// the controller carries out — the reducer never touches a socket.
sealed class CallEffect {
  const CallEffect();
}

/// Tell the peer the call is over, and why.
class SendEnd extends CallEffect {
  const SendEnd({
    required this.callId,
    required this.peerId,
    required this.chatId,
    required this.reason,
  });
  final String callId;
  final String peerId;
  final String chatId;
  final CallEndReason reason;

  @override
  bool operator ==(Object other) =>
      other is SendEnd &&
      other.callId == callId &&
      other.peerId == peerId &&
      other.chatId == chatId &&
      other.reason == reason;

  @override
  int get hashCode => Object.hash(callId, peerId, chatId, reason);

  @override
  String toString() => 'SendEnd($callId, ${reason.wire})';
}

/// Tear down the peer connection and release the microphone.
class ReleaseMedia extends CallEffect {
  const ReleaseMedia();

  @override
  bool operator ==(Object other) => other is ReleaseMedia;

  @override
  int get hashCode => (ReleaseMedia).hashCode;
}

/// The result of one step: the new state and what to do about it.
class CallTransition {
  const CallTransition(this.state, [this.effects = const []]);
  final CallState state;
  final List<CallEffect> effects;
}

/// Maps a reason the PEER sent to what it means on THIS side.
///
/// The asymmetric one is `cancelled`: the caller gave up, and for the callee
/// whose phone was ringing that is a missed call, not a cancelled one.
CallEndReason endReasonFromWire(String wire, {required bool wasIncoming}) =>
    switch (wire) {
      'declined' => CallEndReason.declined,
      'busy' => CallEndReason.busy,
      'cancelled' || 'no_answer' =>
        wasIncoming ? CallEndReason.missed : CallEndReason.noAnswer,
      'failed' => CallEndReason.failed,
      _ => CallEndReason.remoteHangup,
    };

/// The whole rule. Anything not listed leaves the state alone — a stale or
/// duplicated signal is the normal case on a broadcast channel, not an error.
CallTransition reduceCall(CallState s, CallEvent e) {
  CallTransition end(CallEndReason reason, {bool tellPeer = true}) =>
      CallTransition(
        CallState(
          phase: CallPhase.ended,
          callId: s.callId,
          chatId: s.chatId,
          peerId: s.peerId,
          connectedAt: s.connectedAt,
          endReason: reason,
        ),
        [
          if (tellPeer)
            SendEnd(
              callId: s.callId!,
              peerId: s.peerId!,
              chatId: s.chatId!,
              reason: reason,
            ),
          const ReleaseMedia(),
        ],
      );

  bool mine(String callId) => s.callId == callId && s.isBusy;

  switch (e) {
    case LocalDial():
      // A finished call still on screen doesn't block the next one.
      if (s.isBusy) return CallTransition(s);
      return CallTransition(CallState(
        phase: CallPhase.outgoing,
        callId: e.callId,
        chatId: e.chatId,
        peerId: e.peerId,
      ));

    case RemoteInvite():
      if (s.callId == e.callId) return CallTransition(s); // duplicate
      if (s.isBusy) {
        // Turn the newcomer away without touching our own call.
        return CallTransition(s, [
          SendEnd(
            callId: e.callId,
            peerId: e.peerId,
            chatId: e.chatId,
            reason: CallEndReason.busy,
          ),
        ]);
      }
      return CallTransition(CallState(
        phase: CallPhase.incoming,
        callId: e.callId,
        chatId: e.chatId,
        peerId: e.peerId,
      ));

    case DialFailed():
      if (s.phase != CallPhase.outgoing) return CallTransition(s);
      return end(e.reason, tellPeer: false);

    case LocalAccept():
      if (s.phase != CallPhase.incoming) return CallTransition(s);
      return CallTransition(s.copyWith(phase: CallPhase.connecting));

    case RemoteAccept():
      if (s.phase != CallPhase.outgoing || s.callId != e.callId) {
        return CallTransition(s);
      }
      return CallTransition(s.copyWith(phase: CallPhase.connecting));

    case MediaConnected():
      if (s.phase != CallPhase.connecting) return CallTransition(s);
      return CallTransition(
          s.copyWith(phase: CallPhase.active, connectedAt: e.at));

    case MediaInterrupted():
      if (s.phase != CallPhase.active || s.reconnecting) return CallTransition(s);
      return CallTransition(s.copyWith(reconnecting: true));

    case MediaRestored():
      if (s.phase != CallPhase.active || !s.reconnecting) {
        return CallTransition(s);
      }
      return CallTransition(s.copyWith(reconnecting: false));

    case MediaFailed():
      if (s.phase != CallPhase.connecting && s.phase != CallPhase.active) {
        return CallTransition(s);
      }
      return end(e.reason);

    case LocalHangup():
      return switch (s.phase) {
        CallPhase.outgoing => end(CallEndReason.cancelled),
        CallPhase.incoming => end(CallEndReason.declined),
        CallPhase.connecting || CallPhase.active => end(CallEndReason.hangup),
        _ => CallTransition(s),
      };

    case RemoteEnd():
      if (!mine(e.callId)) return CallTransition(s);
      return end(
        endReasonFromWire(e.wireReason,
            wasIncoming: s.phase == CallPhase.incoming),
        tellPeer: false,
      );

    case RingTimeout():
      if (!mine(e.callId)) return CallTransition(s);
      return switch (s.phase) {
        CallPhase.outgoing => end(CallEndReason.noAnswer),
        // The caller runs the same clock and tells us; saying it twice
        // would only race.
        CallPhase.incoming => end(CallEndReason.missed, tellPeer: false),
        // Accepted, but media never came up: the ring clock doubles as the
        // connect timeout.
        CallPhase.connecting => end(CallEndReason.failed),
        _ => CallTransition(s),
      };

    case Dismiss():
      if (s.phase != CallPhase.ended) return CallTransition(s);
      return const CallTransition(CallState.idle);
  }
}
