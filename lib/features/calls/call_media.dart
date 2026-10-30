// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../core/logging/logger_service.dart';
import 'call_gathering.dart';

/// What the media path reports back to the controller.
enum CallMediaStatus {
  /// Audio flows for the first time.
  connected,

  /// The connection dropped after it had worked (ICE `disconnected`), e.g.
  /// because one side changed networks. May still come back by itself.
  interrupted,

  /// Back after an [interrupted], by itself or through an ICE restart.
  restored,

  /// ICE gave up. Final unless a restart brings it back.
  failed,
}

/// The audio leg of one call. An interface so the controller can be tested
/// without a microphone, a network or a native plugin.
abstract class CallMedia {
  /// Opens the microphone and returns a complete SDP offer (candidates
  /// inlined).
  Future<String> createOffer();

  /// Opens the microphone, applies [offerSdp] and returns a complete answer.
  /// Uses what [prepareAnswer] built for the same offer, if anything.
  Future<String> acceptOffer(String offerSdp);

  /// While it rings: builds the connection for [offerSdp] and reserves the
  /// relay paths, WITHOUT the microphone. Nothing is sent and nothing heard
  /// until [acceptOffer]. Best effort: a failure here only costs the head
  /// start, [acceptOffer] then builds from scratch.
  Future<void> prepareAnswer(String offerSdp);

  /// Applies the callee's answer on the caller's side, also the answer to a
  /// [restartOffer].
  Future<void> applyAnswer(String answerSdp);

  /// Caller, mid-call: a new offer with fresh ICE credentials, gathered on
  /// whatever network the device has NOW. The microphone stays as it is.
  Future<String> restartOffer();

  /// Callee, mid-call: applies a [restartOffer] from the peer and returns the
  /// answer, gathered on the current network.
  Future<String> answerRestart(String offerSdp);

  Stream<CallMediaStatus> get status;

  void setMuted(bool muted);

  Future<void> setSpeaker(bool on);

  /// How loud each side is right now, for the waveform. Never throws — a
  /// missing reading is silence, not an error.
  Future<CallAudioLevels> audioLevels();

  /// Releases the microphone and the connection. Safe to call twice.
  Future<void> close();
}

/// How one call may reach the peer: the ICE servers, and whether it must go
/// through the relay.
class CallIceConfig {
  const CallIceConfig({this.servers = const [], this.relayOnly = false});

  /// RTCConfiguration `iceServers` shape.
  final List<Map<String, dynamic>> servers;

  /// Gather relay candidates only. The SDP then carries the relay's address
  /// and none of ours — the peer never learns our IP.
  final bool relayOnly;
}

/// Loudness of both sides, linear amplitude 0..1 as WebRTC reports it
/// (`audioLevel` in the stats; speech mostly sits between 0.01 and 0.3).
class CallAudioLevels {
  const CallAudioLevels({this.local = 0, this.remote = 0});

  static const silent = CallAudioLevels();

  final double local;
  final double remote;
}

typedef CallMediaFactory = CallMedia Function(CallIceConfig config);

final callMediaFactoryProvider =
    Provider<CallMediaFactory>((_) => WebRtcCallMedia.new);

/// Extra ICE servers from `.env` `CALL_ICE_SERVERS` (a JSON list in the
/// RTCConfiguration shape: `[{"urls": "stun:…"}, {"urls": "turn:…",
/// "username": "…", "credential": "…"}]`). For development; the real ones come
/// from the server (`get_call_ice_servers`, 00086).
///
/// Deliberately EMPTY by default — no public STUN server baked in. A STUN
/// server learns the IP address of everyone who calls and when; that is the
/// kind of metadata Chattr exists to not hand out, and a third party's server
/// is the wrong place for it.
List<Map<String, dynamic>> callIceServers() {
  // maybeGet still throws before .env is loaded; a call must not.
  if (!dotenv.isInitialized) return const [];
  final raw = dotenv.maybeGet('CALL_ICE_SERVERS');
  if (raw == null || raw.trim().isEmpty) return const [];
  try {
    final list = jsonDecode(raw) as List<dynamic>;
    return [for (final e in list) Map<String, dynamic>.from(e as Map)];
  } catch (e) {
    logger.warning('CALL_ICE_SERVERS is not valid JSON, ignored: $e',
        tag: 'Calls');
    return const [];
  }
}

/// The longest we wait for candidates before sending what we have. Normally
/// [GatheringWatch] sends much earlier, a few hundred ms after the first
/// usable candidate; this only bounds a network where none ever arrives.
const Duration _gatheringTimeout = Duration(seconds: 3);

/// With relay-only, the TURN allocation is the ONLY candidate — a description
/// sent before it arrives can't connect at all, so it gets more time.
const Duration _relayGatheringTimeout = Duration(seconds: 6);

class WebRtcCallMedia implements CallMedia {
  WebRtcCallMedia(this._config);

  final CallIceConfig _config;

  RTCPeerConnection? _pc;
  MediaStream? _mic;

  /// The ringing head start (see [prepareAnswer]) and the offer it was built
  /// for.
  Future<void>? _prepared;
  String? _preparedOffer;

  /// Web only: plays the peer's audio. Native libwebrtc plays remote audio
  /// by itself; in the browser a remote track is silent until it is attached
  /// to a media element, and the renderer is what creates one (a hidden
  /// `<audio autoplay>`, no widget needed). Without it the PC heard nothing
  /// while the phone heard the PC — found on the first device test.
  RTCVideoRenderer? _remoteAudio;
  final _status = StreamController<CallMediaStatus>.broadcast();
  bool _reported = false;
  bool _interrupted = false;
  bool _closed = false;

  @override
  Stream<CallMediaStatus> get status => _status.stream;

  /// The microphone first, then the connection — the order calls had from
  /// the start; the ringing head start reverses it (see [_prepare]).
  Future<RTCPeerConnection> _open() async {
    await _openMic();
    final pc = await _createPc();
    await _addMic(pc);
    return pc;
  }

  Future<void> _openMic() async {
    _mic = await navigator.mediaDevices.getUserMedia(<String, dynamic>{
      'audio': <String, dynamic>{
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
      },
      'video': false,
    });
  }

  /// Adds the microphone with its stream. After a remote offer this takes
  /// over the receive-only transceiver the offer created and turns it to
  /// send-and-receive, so the answer still carries the stream id: the web
  /// plays a remote track only when it arrives with a stream.
  Future<void> _addMic(RTCPeerConnection pc) async {
    for (final track in _mic!.getAudioTracks()) {
      await pc.addTrack(track, _mic!);
    }
  }

  /// [candidatePool] > 0 makes WebRTC reserve relay paths right away, before
  /// any description exists — used while it rings.
  Future<RTCPeerConnection> _createPc({int candidatePool = 0}) async {
    final pc = await createPeerConnection(<String, dynamic>{
      'iceServers': _config.servers,
      'iceTransportPolicy': _config.relayOnly ? 'relay' : 'all',
      'sdpSemantics': 'unified-plan',
      // One bundled transport: fewer candidates to gather, fewer to leak.
      'bundlePolicy': 'max-bundle',
      'rtcpMuxPolicy': 'require',
      if (candidatePool > 0) 'iceCandidatePoolSize': candidatePool,
    });
    if (kIsWeb) {
      final renderer = RTCVideoRenderer();
      await renderer.initialize();
      _remoteAudio = renderer;
      pc.onTrack = (event) {
        if (event.track.kind != 'audio' || event.streams.isEmpty) return;
        renderer.srcObject = event.streams.first;
      };
    }
    pc.onIceConnectionState = (state) {
      switch (state) {
        case RTCIceConnectionState.RTCIceConnectionStateConnected:
        case RTCIceConnectionState.RTCIceConnectionStateCompleted:
          if (!_reported) {
            _reported = true;
            _report(CallMediaStatus.connected);
          } else if (_interrupted) {
            _interrupted = false;
            _report(CallMediaStatus.restored);
          }
        case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
          // Often recovers by itself (a Wi-Fi hiccup); the controller decides
          // when to restart.
          if (_reported && !_interrupted) {
            _interrupted = true;
            _report(CallMediaStatus.interrupted);
          }
        case RTCIceConnectionState.RTCIceConnectionStateFailed:
          if (_reported) _interrupted = true;
          _report(CallMediaStatus.failed);
        default:
          break;
      }
    };
    _pc = pc;
    return pc;
  }

  void _report(CallMediaStatus s) {
    if (_closed || _status.isClosed) return;
    _status.add(s);
  }

  /// Sets the local description and returns it once it holds enough
  /// candidates (see [GatheringWatch]). The handlers go on BEFORE
  /// [setLocal]: gathering starts with it, and a candidate reported before
  /// anyone listens is lost to the count.
  Future<String> _gatheredSdp(
    RTCPeerConnection pc,
    Future<void> Function() setLocal, {
    Duration grace = gatheringGrace,
  }) async {
    final relayOnly = _config.relayOnly;
    final watch = GatheringWatch(
      relayOnly: relayOnly,
      timeout: relayOnly ? _relayGatheringTimeout : _gatheringTimeout,
      grace: grace,
    );
    pc.onIceCandidate = (c) => watch.onCandidate(c.candidate);
    pc.onIceGatheringState = (state) {
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete) {
        watch.onComplete();
      }
    };
    try {
      await setLocal();
      if (pc.iceGatheringState ==
          RTCIceGatheringState.RTCIceGatheringStateComplete) {
        watch.onComplete();
      }
      final outcome = await watch.done;
      logger.info(watch.summary(outcome), tag: 'Calls');
    } finally {
      watch.dispose();
    }
    final desc = await pc.getLocalDescription();
    final sdp = desc?.sdp;
    if (sdp == null || sdp.isEmpty) throw StateError('no local description');
    if (watch.firstUsableAt != null &&
        !sdpHasUsableCandidate(sdp, relayOnly: relayOnly)) {
      // Not expected — browsers and libwebrtc both write each candidate into
      // the local description as it arrives. Say so loudly if one doesn't:
      // the peer would get a description it cannot connect to.
      logger.warning(
        'Usable candidate reported but missing from the local description',
        tag: 'Calls',
      );
    }
    return sdp;
  }

  @override
  Future<String> createOffer() async {
    final pc = await _open();
    final offer = await pc.createOffer(<String, dynamic>{
      'offerToReceiveAudio': true,
      'offerToReceiveVideo': false,
    });
    return _gatheredSdp(pc, () => pc.setLocalDescription(offer));
  }

  @override
  Future<void> prepareAnswer(String offerSdp) =>
      _prepared ??= _prepare(offerSdp);

  Future<void> _prepare(String offerSdp) async {
    final pc = await _createPc(candidatePool: 1);
    await pc.setRemoteDescription(RTCSessionDescription(offerSdp, 'offer'));
    _preparedOffer = offerSdp;
  }

  @override
  Future<String> acceptOffer(String offerSdp) async {
    final prepared = _prepared;
    if (prepared != null) {
      try {
        await prepared;
      } catch (e) {
        logger.warning('Ringing head start failed, building anew: $e',
            tag: 'Calls');
      }
    }
    final pc = _pc;
    if (pc != null && _preparedOffer == offerSdp && !_closed) {
      await _openMic();
      await _addMic(pc);
      final answer = await pc.createAnswer(<String, dynamic>{});
      // The pooled candidates arrive in one go as soon as the description is
      // set; a short grace is enough for that batch.
      return _gatheredSdp(pc, () => pc.setLocalDescription(answer),
          grace: pooledGatheringGrace);
    }
    // No head start (or it failed): drop any half-built connection.
    await pc?.close();
    _pc = null;
    final fresh = await _open();
    await fresh.setRemoteDescription(RTCSessionDescription(offerSdp, 'offer'));
    final answer = await fresh.createAnswer(<String, dynamic>{});
    return _gatheredSdp(fresh, () => fresh.setLocalDescription(answer));
  }

  @override
  Future<String> restartOffer() async {
    final pc = _pc;
    if (pc == null) throw StateError('no peer connection');
    await pc.restartIce();
    final offer = await pc.createOffer(<String, dynamic>{
      'offerToReceiveAudio': true,
      'offerToReceiveVideo': false,
    });
    return _gatheredSdp(pc, () => pc.setLocalDescription(offer));
  }

  @override
  Future<String> answerRestart(String offerSdp) async {
    final pc = _pc;
    if (pc == null) throw StateError('no peer connection');
    await pc.setRemoteDescription(RTCSessionDescription(offerSdp, 'offer'));
    final answer = await pc.createAnswer(<String, dynamic>{});
    return _gatheredSdp(pc, () => pc.setLocalDescription(answer));
  }

  @override
  Future<void> applyAnswer(String answerSdp) async {
    final pc = _pc;
    if (pc == null) throw StateError('no peer connection');
    await pc.setRemoteDescription(RTCSessionDescription(answerSdp, 'answer'));
  }

  @override
  void setMuted(bool muted) {
    for (final t in _mic?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      t.enabled = !muted;
    }
  }

  @override
  Future<CallAudioLevels> audioLevels() async {
    final pc = _pc;
    if (pc == null || _closed) return CallAudioLevels.silent;
    try {
      var local = 0.0;
      var remote = 0.0;
      for (final r in await pc.getStats()) {
        final v = r.values;
        if (v['kind'] != 'audio') continue;
        final level = _asDouble(v['audioLevel']);
        if (level == null) continue;
        // `media-source` is our microphone, `inbound-rtp` the peer's voice.
        if (r.type == 'media-source') local = level;
        if (r.type == 'inbound-rtp') remote = level;
      }
      return CallAudioLevels(local: local, remote: remote);
    } catch (_) {
      return CallAudioLevels.silent;
    }
  }

  // Stats arrive as num on web and native, as String on some older builds.
  static double? _asDouble(Object? v) => switch (v) {
        num n => n.toDouble(),
        String s => double.tryParse(s),
        _ => null,
      };

  @override
  Future<void> setSpeaker(bool on) async {
    // Earpiece vs. loudspeaker only exists on phones; desktop and web play
    // through whatever output the system has chosen.
    if (kIsWeb) return;
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS) {
      return;
    }
    try {
      await Helper.setSpeakerphoneOn(on);
    } catch (e) {
      logger.warning('Speaker switch failed: $e', tag: 'Calls');
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      for (final t in _mic?.getTracks() ?? const <MediaStreamTrack>[]) {
        await t.stop();
      }
      await _mic?.dispose();
      await _pc?.close();
      final remote = _remoteAudio;
      if (remote != null) {
        remote.srcObject = null;
        await remote.dispose();
      }
    } catch (e) {
      logger.warning('Closing call media failed: $e', tag: 'Calls');
    } finally {
      _mic = null;
      _pc = null;
      _remoteAudio = null;
      await _status.close();
    }
  }
}
