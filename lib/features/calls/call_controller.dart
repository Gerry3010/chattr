// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/events/event_bus_provider.dart';
import '../../core/events/event_types.dart';
import '../../core/logging/logger_service.dart';
import 'call_ice_config.dart';
import 'call_keep_alive.dart';
import 'call_log.dart';
import 'call_log_writer.dart';
import 'call_proximity.dart';
import 'call_system_ui.dart';
import 'call_media.dart';
import 'call_ringer.dart';
import 'call_rules.dart';
import 'call_signal.dart';
import 'call_signaling.dart';

/// How long the end screen stays before it clears itself. Long enough to read
/// "Besetzt", short enough not to sit in the way.
const Duration callEndScreenHold = Duration(seconds: 3);

/// When the connection drops mid-call (network change): how long to wait for
/// it to come back by itself, how often to retry the restart, and how long
/// to keep the call before giving up. A provider so tests can shrink them.
class CallRestartTiming {
  const CallRestartTiming({
    this.firstTry = const Duration(seconds: 1),
    this.retry = const Duration(seconds: 3),
    this.window = const Duration(seconds: 20),
  });

  /// A Wi-Fi hiccup often heals within a second; a restart then is noise.
  final Duration firstTry;

  /// No answer or still dead: a new round after this.
  final Duration retry;

  /// From the first interruption. WebRTC alone gives up after ~10 s, which
  /// is too short for walking out of the house; an old peer that cannot
  /// restart still ends the call at its own 10 s and tells us.
  final Duration window;
}

final callRestartTimingProvider =
    Provider<CallRestartTiming>((_) => const CallRestartTiming());

/// Whether the app is in front right now. A provider so a test can say
/// "backgrounded" without a running Flutter binding.
final callAppInForegroundProvider = Provider<bool Function()>((_) => () {
      final state = WidgetsBinding.instance.lifecycleState;
      return state == null || state == AppLifecycleState.resumed;
    });

/// Runs THE call of this device — there is at most one.
///
/// The decisions live in `reduceCall` (pure, tested); this class only carries
/// them out: it feeds taps, signals and timers into the reducer, then does
/// what the effects say (tell the peer, release the microphone). WebRTC sits
/// behind [CallMedia], the seal behind [CallSignaling], so the whole flow can
/// be driven in a test without either.
///
/// Global and kept alive by the call overlay in `MaterialApp.builder`, so an
/// invite rings wherever the user is — not only with the right chat open.
class CallController extends Notifier<CallState> {
  CallMedia? _media;
  StreamSubscription<CallMediaStatus>? _mediaSub;
  Timer? _ringTimer;
  Timer? _endTimer;

  /// The caller's offer, held from the invite until the user accepts.
  String? _pendingOfferSdp;

  /// The server-side id of the ringing invite — what the system call UI
  /// (stage 3) knows the call by.
  String? _incomingSignalId;

  /// Accepted from the system UI (CallKit / Android). Then that UI owns the
  /// call until it ends; taking it down earlier would cut the audio session
  /// out from under the call on iOS.
  bool _acceptedViaSystem = false;

  /// Whether the current call rang HERE (it came in) — decides the wording
  /// of its chat entry. Set when a call starts, read when it ends.
  bool _incoming = false;

  /// The ICE config for the ringing invite, fetched while it rings so that
  /// "accept" does not wait for that round trip as well. Holds the config or
  /// the error (see [_loadConfigSettled]).
  ({String callId, Future<Object> result})? _prefetchedConfig;

  /// The connection built while it rings (see [CallMedia.prepareAnswer]):
  /// relay paths reserved, offer applied, microphone still closed. "Accept"
  /// then only adds the microphone and answers.
  ({String callId, Future<CallMedia?> media})? _warm;

  /// ICE restart after a network change. Only the caller starts a round, so
  /// the two sides never restart against each other; the callee answers.
  /// Caller: the last round sent. Callee: the last round answered.
  int _restartSeq = 0;
  Timer? _restartTimer;
  Timer? _reconnectDeadline;
  final _reconnectClock = Stopwatch();

  /// Times the setup of the current call for the log: from the tap on dial
  /// (caller) or on accept (callee) to "connected".
  final _setupClock = Stopwatch();

  /// Signal ids already handled. The bus may deliver twice after a
  /// reconnect; a duplicated invite must not ring twice.
  final _seenSignals = <String>{};

  @override
  CallState build() {
    final bus = ref.watch(eventBusProvider);
    if (bus != null) {
      final sub = bus.eventStreamOf<CallSignalEvent>().listen(_onBusEvent);
      ref.onDispose(sub.cancel);
    }
    // Riverpod forbids ref.read inside onDispose — take it now.
    final ringer = ref.read(callRingerProvider);
    final proximity = ref.read(callProximityProvider);
    final keepAlive = ref.read(callKeepAliveProvider);
    final hangUps = keepAlive.hangUpRequests.listen((_) => hangUp());
    ref.onDispose(() {
      unawaited(hangUps.cancel());
      proximity.setActive(false);
      keepAlive.setActive(false);
      _ringTimer?.cancel();
      _endTimer?.cancel();
      _stopReconnecting();
      ringer.stop();
      unawaited(_releaseMedia());
    });
    return CallState.idle;
  }

  // ── Taps ──────────────────────────────────────────────────────────────────

  /// Rings [peerId] in the 1:1 chat [chatId].
  Future<void> dial({required String chatId, required String peerId}) async {
    final callId = const Uuid().v4();
    _apply(LocalDial(callId: callId, chatId: chatId, peerId: peerId));
    if (state.callId != callId) return; // already in a call
    _incoming = false;

    _setupClock
      ..reset()
      ..start();
    try {
      // Two independent round trips: start both, wait for both.
      final config = _loadConfigSettled(chatId, peerId);
      final canTake = await ref
          .read(callSignalingProvider)
          .peerCanTakeCalls(chatId: chatId, peerId: peerId);
      if (!_stillOn(callId, CallPhase.outgoing)) return;
      if (!canTake) {
        _apply(const DialFailed(CallEndReason.unavailable));
        return;
      }
      final media = await _startMedia(
          callId: callId, phase: CallPhase.outgoing, config: config);
      if (media == null) return;
      final checked = _setupClock.elapsedMilliseconds;
      final offer = await media.createOffer();
      if (!_stillOn(callId, CallPhase.outgoing)) return;
      final offered = _setupClock.elapsedMilliseconds;
      await ref.read(callSignalingProvider).send(
            chatId: chatId,
            peerId: peerId,
            signal: CallSignal(
              type: CallSignalType.invite,
              callId: callId,
              sentAt: DateTime.now(),
              sdp: offer,
            ),
            kind: 'invite',
          );
      logger.info(
        'Dial: checks + config $checked ms, offer ${offered - checked} ms, '
        'invite out at ${_setupClock.elapsedMilliseconds} ms',
        tag: 'Calls',
      );
    } on CallPeerNotReady {
      _apply(const DialFailed(CallEndReason.unavailable));
    } on CallPeerKeyMismatch {
      _apply(const DialFailed(CallEndReason.keyChanged));
    } on CallRelayUnavailable {
      _apply(const DialFailed(CallEndReason.relayUnavailable));
    } catch (e) {
      logger.warning('Dial failed: $e', tag: 'Calls');
      _apply(DialFailed(_isMicDenied(e)
          ? CallEndReason.micDenied
          : CallEndReason.failed));
    }
  }

  Future<void> accept() async {
    final offer = _pendingOfferSdp;
    final callId = state.callId;
    final chatId = state.chatId;
    final peerId = state.peerId;
    if (state.phase != CallPhase.incoming ||
        offer == null ||
        callId == null ||
        chatId == null ||
        peerId == null) {
      return;
    }
    final prefetched = _prefetchedConfig;
    final warm = _warm?.callId == callId ? _warm!.media : null;
    _setupClock
      ..reset()
      ..start();
    _apply(const LocalAccept());
    _pendingOfferSdp = null;

    try {
      var media = warm == null ? null : await warm;
      if (!_stillOn(callId, CallPhase.connecting)) return;
      if (media == null || !identical(media, _media)) {
        var config = prefetched?.callId == callId
            ? prefetched!.result
            : _loadConfigSettled(chatId, peerId);
        // A prefetch that failed while it rang (offline for a moment) gets one
        // fresh try now, rather than costing the call.
        config = config.then<Object>((r) =>
            r is CallIceConfig ? r : _loadConfigSettled(chatId, peerId));
        media = await _startMedia(
            callId: callId, phase: CallPhase.connecting, config: config);
        if (media == null) return;
      }
      final ready = _setupClock.elapsedMilliseconds;
      final answer = await media.acceptOffer(offer);
      if (!_stillOn(callId, CallPhase.connecting)) return;
      final answered = _setupClock.elapsedMilliseconds;
      await ref.read(callSignalingProvider).send(
            chatId: chatId,
            peerId: peerId,
            signal: CallSignal(
              type: CallSignalType.accept,
              callId: callId,
              sentAt: DateTime.now(),
              sdp: answer,
            ),
          );
      logger.info(
        'Accept: config $ready ms, answer ${answered - ready} ms, '
        'answer out at ${_setupClock.elapsedMilliseconds} ms',
        tag: 'Calls',
      );
    } on CallRelayUnavailable {
      _apply(const MediaFailed(CallEndReason.relayUnavailable));
    } catch (e) {
      logger.warning('Accept failed: $e', tag: 'Calls');
      _apply(const MediaFailed());
    }
  }

  void hangUp() => _apply(const LocalHangup());

  void dismiss() => _apply(const Dismiss());

  /// Both sides' loudness for the waveform. Muted counts as silent: the
  /// microphone still picks up sound, but none of it leaves the device, and
  /// the wave should not suggest otherwise.
  Future<CallAudioLevels> audioLevels() async {
    final media = _media;
    if (media == null || state.phase != CallPhase.active) {
      return CallAudioLevels.silent;
    }
    final l = await media.audioLevels();
    return state.muted ? CallAudioLevels(remote: l.remote) : l;
  }

  void toggleMute() {
    if (!state.isBusy) return;
    final muted = !state.muted;
    _media?.setMuted(muted);
    state = state.copyWith(muted: muted);
  }

  void toggleSpeaker() {
    if (!state.isBusy) return;
    final on = !state.speakerOn;
    unawaited(_media?.setSpeaker(on));
    state = state.copyWith(speakerOn: on);
    _syncProximity();
  }

  void _writeCallLog(CallState s) {
    final chatId = s.chatId;
    final reason = s.endReason;
    if (chatId == null || reason == null) return;
    final now = DateTime.now();
    final entry = callLogEntryFor(
      incoming: _incoming,
      reason: reason,
      connectedAt: s.connectedAt,
      endedAt: now,
    );
    if (entry == null) return;
    unawaited(ref
        .read(callLogWriterProvider)
        .write(chatId: chatId, entry: entry, at: now));
  }

  /// Screen off at the ear — see [wantsProximityLock].
  void _syncProximity() {
    final s = state;
    final underWay = s.phase == CallPhase.outgoing ||
        s.phase == CallPhase.connecting ||
        s.phase == CallPhase.active;
    ref.read(callProximityProvider).setActive(wantsProximityLock(
      callUnderWay: underWay,
      speakerOn: s.speakerOn,
    ));
    // Microphone and sound in the background (Android) — for as long as the
    // call is under way, speaker or not.
    ref.read(callKeepAliveProvider).setActive(underWay);
  }

  // ── Signals ───────────────────────────────────────────────────────────────

  Future<void> _onBusEvent(CallSignalEvent event) async {
    if (!_seenSignals.add(event.signalId)) return;
    if (_seenSignals.length > 256) _seenSignals.remove(_seenSignals.first);

    final signal = await ref.read(callSignalingProvider).open(event);
    if (signal == null) return;
    await handleSignal(
      chatId: event.chatId,
      senderId: event.senderId,
      signal: signal,
      signalId: event.signalId,
    );
  }

  // ── System call UI (stage 3) ──────────────────────────────────────────────

  /// The user accepted in the system call UI. If the invite already arrived
  /// over the bus, answer it; otherwise the app was closed — fetch the sealed
  /// invite the push pointed at, open it like any signal, then answer.
  Future<void> acceptFromSystem(String signalId) async {
    // Already answered (the accept can reach us twice: as an event and from
    // the list of active calls at start) — fetching again would find the
    // invite gone and take the system UI down under a running call.
    if (_incomingSignalId == signalId && state.isBusy &&
        state.phase != CallPhase.incoming) {
      return;
    }
    if (!await _ensureInvite(signalId)) return;
    _acceptedViaSystem = true;
    await accept();
  }

  /// The user declined in the system call UI.
  Future<void> declineFromSystem(String signalId) async {
    if (!await _ensureInvite(signalId)) return;
    hangUp();
  }

  /// The system UI ended the call — CallKit's red button, a headset, or
  /// Android's Telecom. Only the call that rang through it; the echo of our
  /// own `end` (we ended it first) finds nothing busy and does nothing.
  void endFromSystem(String signalId) {
    if (_incomingSignalId != signalId || !state.isBusy) return;
    hangUp();
  }

  Future<bool> _ensureInvite(String signalId) async {
    if (state.phase == CallPhase.incoming && _incomingSignalId == signalId) {
      return true;
    }
    final signaling = ref.read(callSignalingProvider);
    CallSignalEvent? event;
    try {
      event = await signaling.fetchInvite(signalId);
    } catch (e) {
      // Offline, or an id the server cannot read: the system UI must not
      // sit there as a call that never comes.
      logger.warning('Fetching the invite failed: $e', tag: 'Calls');
    }
    if (event == null) {
      logger.warning('Invite for the system call is gone', tag: 'Calls');
      unawaited(ref.read(callSystemUiProvider).end(signalId));
      return false;
    }
    _seenSignals.add(signalId);
    final signal = await signaling.open(event);
    if (signal == null) {
      unawaited(ref.read(callSystemUiProvider).end(signalId));
      return false;
    }
    await handleSignal(
      chatId: event.chatId,
      senderId: event.senderId,
      signal: signal,
      signalId: signalId,
    );
    return state.phase == CallPhase.incoming && _incomingSignalId == signalId;
  }

  /// One opened, verified signal. Public for tests; production gets here only
  /// through [_onBusEvent].
  Future<void> handleSignal({
    required String chatId,
    required String senderId,
    required CallSignal signal,
    String? signalId,
  }) async {
    // A signal about OUR call must come from the peer of our call. The call
    // id only ever travelled sealed to that peer, so nobody else should know
    // it — but that is an argument, and this is a check.
    if (state.callId == signal.callId && state.peerId != senderId) return;

    switch (signal.type) {
      case CallSignalType.invite:
        final before = state.callId;
        _apply(RemoteInvite(
          callId: signal.callId,
          chatId: chatId,
          peerId: senderId,
        ));
        if (state.callId == signal.callId && before != signal.callId) {
          _pendingOfferSdp = signal.sdp;
          _incomingSignalId = signalId;
          _acceptedViaSystem = false;
          _incoming = true;
          // Only the config, no microphone: nothing is opened before the
          // user says yes.
          final config = _loadConfigSettled(chatId, senderId);
          _prefetchedConfig = (callId: signal.callId, result: config);
          _warm = (
            callId: signal.callId,
            media: _warmUp(signal.callId, config, signal.sdp!),
          );
        }
      case CallSignalType.accept:
        if (state.phase != CallPhase.outgoing ||
            state.callId != signal.callId) {
          return;
        }
        _apply(RemoteAccept(signal.callId));
        logger.info(
          'Answer in at ${_setupClock.elapsedMilliseconds} ms after dial',
          tag: 'Calls',
        );
        try {
          await _media?.applyAnswer(signal.sdp!);
        } catch (e) {
          logger.warning('Applying answer failed: $e', tag: 'Calls');
          _apply(const MediaFailed());
        }
      case CallSignalType.end:
        _apply(RemoteEnd(signal.callId, signal.reason ?? 'hangup'));
      case CallSignalType.restart:
        await _answerRestart(chatId, senderId, signal);
      case CallSignalType.restarted:
        if (state.callId != signal.callId ||
            state.phase != CallPhase.active ||
            _incoming ||
            signal.seq != _restartSeq) {
          return;
        }
        try {
          await _media?.applyAnswer(signal.sdp!);
        } catch (e) {
          logger.warning('Applying restart answer failed: $e', tag: 'Calls');
        }
    }
  }

  // ── Network change mid-call ───────────────────────────────────────────────

  void _onInterrupted() {
    if (state.phase != CallPhase.active) return;
    final first = !state.reconnecting;
    _apply(const MediaInterrupted());
    final timing = ref.read(callRestartTimingProvider);
    if (first) {
      _reconnectClock
        ..reset()
        ..start();
      logger.info('Connection interrupted, trying to restore', tag: 'Calls');
    }
    _reconnectDeadline ??= Timer(timing.window, () {
      logger.info('Not restored within ${timing.window.inSeconds} s',
          tag: 'Calls');
      _apply(const MediaFailed());
    });
    if (!_incoming && _restartTimer == null) {
      _restartTimer = Timer(timing.firstTry, _restart);
    }
  }

  void _onRestored() {
    _stopReconnecting();
    if (!state.reconnecting) return;
    logger.info(
      'Connection restored after ${_reconnectClock.elapsedMilliseconds} ms '
      '(restart round $_restartSeq)',
      tag: 'Calls',
    );
    _apply(const MediaRestored());
  }

  void _stopReconnecting() {
    _restartTimer?.cancel();
    _restartTimer = null;
    _reconnectDeadline?.cancel();
    _reconnectDeadline = null;
  }

  /// Caller: one restart round — new ICE credentials, gathered on the network
  /// the device has now, sent sealed like every signal. Repeats until the
  /// connection is back or the window closes.
  Future<void> _restart() async {
    _restartTimer = null;
    final media = _media;
    final callId = state.callId;
    final chatId = state.chatId;
    final peerId = state.peerId;
    if (state.phase != CallPhase.active ||
        !state.reconnecting ||
        media == null ||
        callId == null ||
        chatId == null ||
        peerId == null) {
      return;
    }
    final seq = ++_restartSeq;
    try {
      final offer = await media.restartOffer();
      if (state.callId == callId && state.reconnecting && seq == _restartSeq) {
        await ref.read(callSignalingProvider).send(
              chatId: chatId,
              peerId: peerId,
              signal: CallSignal(
                type: CallSignalType.restart,
                callId: callId,
                sentAt: DateTime.now(),
                sdp: offer,
                seq: seq,
              ),
            );
        logger.info(
          'Restart round $seq sent at ${_reconnectClock.elapsedMilliseconds} ms',
          tag: 'Calls',
        );
      }
    } catch (e) {
      // Offline for the moment, most likely: the next round tries again.
      logger.warning('Restart round $seq failed: $e', tag: 'Calls');
    }
    if (state.callId == callId &&
        state.reconnecting &&
        _restartTimer == null) {
      _restartTimer =
          Timer(ref.read(callRestartTimingProvider).retry, _restart);
    }
  }

  /// Callee: answers the caller's restart round on the current network.
  Future<void> _answerRestart(
    String chatId,
    String senderId,
    CallSignal signal,
  ) async {
    final seq = signal.seq;
    final media = _media;
    if (state.callId != signal.callId ||
        state.phase != CallPhase.active ||
        !_incoming ||
        seq == null ||
        seq <= _restartSeq ||
        media == null) {
      return;
    }
    _restartSeq = seq;
    try {
      final answer = await media.answerRestart(signal.sdp!);
      if (state.callId != signal.callId || seq != _restartSeq) return;
      await ref.read(callSignalingProvider).send(
            chatId: chatId,
            peerId: senderId,
            signal: CallSignal(
              type: CallSignalType.restarted,
              callId: signal.callId,
              sentAt: DateTime.now(),
              sdp: answer,
              seq: seq,
            ),
          );
    } catch (e) {
      logger.warning('Answering restart round $seq failed: $e', tag: 'Calls');
    }
  }

  /// How long to give PushKit's CallKit call to show up before the app
  /// rings by itself. The invite usually arrives over the bus first.
  static const _systemRingGrace = Duration(milliseconds: 1500);

  /// The in-app ringtone for an incoming call — unless the system UI rings
  /// for it already (iOS, see [CallSystemUi.ringsInForeground]). Then CallKit
  /// plays our tone, and a second one in the app would be cut off by it.
  /// Without a CallKit call (no VoIP token yet, push lost) the app still
  /// rings, so a call is never silent.
  Future<void> _ringIncoming(String callId) async {
    final systemUi = ref.read(callSystemUiProvider);
    if (systemUi.ringsInForeground) {
      await Future<void>.delayed(_systemRingGrace);
      if (!_stillOn(callId, CallPhase.incoming)) return;
      // Read only now: the phase change that got us here runs before the
      // invite's signal id is stored.
      final sid = _incomingSignalId;
      if (sid != null && await systemUi.isShowing(sid)) return;
      if (!_stillOn(callId, CallPhase.incoming)) return;
    }
    ref.read(callRingerProvider).start();
  }

  // ── Plumbing ──────────────────────────────────────────────────────────────

  void _apply(CallEvent event) {
    final before = state;
    final t = reduceCall(before, event);
    state = t.state;
    for (final effect in t.effects) {
      switch (effect) {
        case SendEnd():
          unawaited(_sendEnd(effect));
        case ReleaseMedia():
          unawaited(_releaseMedia());
      }
    }
    if (before.phase != state.phase) _onPhaseChange(state);
  }

  void _onPhaseChange(CallState s) {
    final ringer = ref.read(callRingerProvider);
    _ringTimer?.cancel();
    _endTimer?.cancel();
    switch (s.phase) {
      case CallPhase.outgoing || CallPhase.incoming || CallPhase.connecting:
        // The same clock is the ring timeout and, once accepted, the connect
        // timeout (see reduceCall).
        final callId = s.callId!;
        _ringTimer = Timer(ringTimeout, () => _apply(RingTimeout(callId)));
      case CallPhase.ended:
        _endTimer = Timer(callEndScreenHold, dismiss);
        _writeCallLog(s);
        _stopReconnecting();
        _restartSeq = 0;
      case CallPhase.active || CallPhase.idle:
        break;
    }
    switch (s.phase) {
      case CallPhase.incoming:
        // In the background the system call UI rings (stage 3); a second,
        // in-app ringtone on top would play into a pocket.
        if (_inForeground) unawaited(_ringIncoming(s.callId!));
      case CallPhase.outgoing:
        ringer.startRingback();
      default:
        ringer.stop();
    }
    // Leaving "ringing": the system UI goes — at once if the call was taken
    // in the app, at the very end if the system UI took it (it holds the
    // audio session on iOS).
    final sid = _incomingSignalId;
    if (sid != null &&
        s.phase != CallPhase.incoming &&
        (!_acceptedViaSystem || s.phase == CallPhase.ended)) {
      unawaited(ref.read(callSystemUiProvider).end(sid));
      if (s.phase == CallPhase.ended || !_acceptedViaSystem) {
        _incomingSignalId = null;
      }
    }
    if (s.phase == CallPhase.ended) ringer.playEndTone();
    if (s.phase != CallPhase.incoming) {
      _pendingOfferSdp = null;
      _prefetchedConfig = null;
      _warm = null;
    }
    _syncProximity();
  }

  bool get _inForeground => ref.read(callAppInForegroundProvider)();

  /// Waits for the ICE config, then opens the media — or returns null when
  /// the call ended while the config was on its way (nothing opened, nothing
  /// to release). A failed load rethrows its error here.
  Future<CallMedia?> _startMedia({
    required String callId,
    required CallPhase phase,
    required Future<Object> config,
  }) async {
    final loaded = await config;
    if (!_stillOn(callId, phase)) return null;
    if (loaded is! CallIceConfig) throw loaded;
    final media = ref.read(callMediaFactoryProvider)(loaded);
    _adoptMedia(media);
    return media;
  }

  /// Builds the connection while it rings, without the microphone, so that
  /// "accept" has less to do. Best effort: null when the call moved on or
  /// the config is missing; then accept builds as before.
  Future<CallMedia?> _warmUp(
    String callId,
    Future<Object> config,
    String offerSdp,
  ) async {
    final loaded = await config;
    if (!_stillOn(callId, CallPhase.incoming) ||
        loaded is! CallIceConfig ||
        _media != null) {
      return null;
    }
    final media = ref.read(callMediaFactoryProvider)(loaded);
    _adoptMedia(media);
    try {
      await media.prepareAnswer(offerSdp);
    } catch (e) {
      // acceptOffer notices the missing head start and builds anew.
      logger.warning('Ringing head start failed: $e', tag: 'Calls');
    }
    return media;
  }

  /// Makes [media] the call's media and follows its status. Every end of a
  /// call releases it (ReleaseMedia), a declined ringing one included.
  void _adoptMedia(CallMedia media) {
    _media = media;
    _mediaSub = media.status.listen((s) {
      if (!identical(_media, media)) return;
      switch (s) {
        case CallMediaStatus.connected:
          logger.info(
            'Connected at ${_setupClock.elapsedMilliseconds} ms after '
            '${_incoming ? 'accept' : 'dial'}',
            tag: 'Calls',
          );
          _apply(MediaConnected(DateTime.now()));
        case CallMediaStatus.interrupted:
          _onInterrupted();
        case CallMediaStatus.restored:
          _onRestored();
        case CallMediaStatus.failed:
          // Before the call ever connected there is nothing to restore. Mid-
          // call, the restart window decides (see _onInterrupted).
          if (state.phase == CallPhase.active) {
            _onInterrupted();
          } else {
            _apply(const MediaFailed());
          }
      }
    });
  }

  /// Loads the ICE config with its outcome settled either way: the config, or
  /// the error as a value. Started early and awaited later, so a failure
  /// must not surface as unhandled in between.
  Future<Object> _loadConfigSettled(String chatId, String peerId) => ref
      .read(callIceConfigLoaderProvider)
      .load(chatId: chatId, peerId: peerId)
      .then<Object>((c) => c, onError: (Object e) => e);

  /// Whether [callId] is still the call, in [phase] — checked after every
  /// await, because the user may hang up while the microphone opens.
  bool _stillOn(String callId, CallPhase phase) =>
      state.callId == callId && state.phase == phase;

  Future<void> _releaseMedia() async {
    final media = _media;
    _media = null;
    await _mediaSub?.cancel();
    _mediaSub = null;
    await media?.close();
  }

  Future<void> _sendEnd(SendEnd e) async {
    try {
      await ref.read(callSignalingProvider).send(
            chatId: e.chatId,
            peerId: e.peerId,
            signal: CallSignal(
              type: CallSignalType.end,
              callId: e.callId,
              sentAt: DateTime.now(),
              reason: e.reason.wire,
            ),
            // The caller gave up before anyone answered: a closed app on the
            // other side is still ringing from the push and must stop.
            kind: e.reason == CallEndReason.cancelled ||
                    e.reason == CallEndReason.noAnswer
                ? 'cancel'
                : null,
          );
    } catch (err) {
      // The peer's own ring/connect timeout ends it on their side too.
      logger.warning('Could not send call end: $err', tag: 'Calls');
    }
  }

  static bool _isMicDenied(Object e) {
    final s = e.toString().toLowerCase();
    return s.contains('notallowed') ||
        s.contains('permission') ||
        s.contains('denied');
  }
}

final callControllerProvider =
    NotifierProvider<CallController, CallState>(CallController.new);
