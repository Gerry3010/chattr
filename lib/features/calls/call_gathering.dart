// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

/// Why a description was sent when it was.
enum GatheringOutcome {
  /// WebRTC reported gathering as complete.
  complete,

  /// A usable candidate arrived and the grace period after it ran out.
  enough,

  /// Neither happened before the timeout.
  timeout,
}

/// After the first usable candidate, how long to wait for the rest of the
/// same batch. The other paths to the same relay (TCP, IPv6) follow within a
/// round trip or two; whatever comes later is a path that would rarely win.
const Duration gatheringGrace = Duration(milliseconds: 400);

/// The grace when the candidates were reserved while it rang (candidate
/// pool): they are delivered together the moment the description is set.
const Duration pooledGatheringGrace = Duration(milliseconds: 150);

/// The ICE type of one candidate line (`host`, `srflx`, `relay`, `prflx`).
String? candidateType(String? candidate) =>
    candidate == null ? null : RegExp(r' typ (\w+)').firstMatch(candidate)?.group(1);

/// Whether [candidate] can carry a call across networks on its own: through
/// the relay when only the relay is allowed, otherwise relay or a public
/// (STUN) address. Host candidates alone only reach the same network.
bool isUsableCandidate(String? candidate, {required bool relayOnly}) {
  final type = candidateType(candidate);
  return relayOnly ? type == 'relay' : (type == 'relay' || type == 'srflx');
}

/// Whether [sdp] already carries a usable candidate line.
bool sdpHasUsableCandidate(String sdp, {required bool relayOnly}) => sdp
    .split('\n')
    .where((l) => l.startsWith('a=candidate:'))
    .any((l) => isUsableCandidate(l, relayOnly: relayOnly));

/// Decides when a local description holds enough candidates to be sent.
///
/// Waiting for WebRTC's own "gathering complete" made calls slow: it only
/// fires after every network interface has heard back from every server. An
/// IPv6 route that leads nowhere, or a TCP allocation taking its time, held
/// the description until the timeout (3 s, 6 s through the relay), and that
/// happened twice per call: before the invite went out and again after
/// "accept". One usable candidate is enough to connect.
class GatheringWatch {
  GatheringWatch({
    required this.relayOnly,
    required Duration timeout,
    this.grace = gatheringGrace,
  }) {
    _clock.start();
    _cap = Timer(timeout, () => _finish(GatheringOutcome.timeout));
  }

  final bool relayOnly;
  final Duration grace;

  final _clock = Stopwatch();
  final _done = Completer<GatheringOutcome>();
  late final Timer _cap;
  Timer? _grace;

  /// Candidates seen so far, by ICE type.
  final Map<String, int> types = {};

  Duration? firstUsableAt;
  Duration? finishedAt;

  Future<GatheringOutcome> get done => _done.future;

  void onCandidate(String? candidate) {
    if (_done.isCompleted) return;
    final type = candidateType(candidate) ?? '?';
    types[type] = (types[type] ?? 0) + 1;
    if (_grace == null && isUsableCandidate(candidate, relayOnly: relayOnly)) {
      firstUsableAt = _clock.elapsed;
      _grace = Timer(grace, () => _finish(GatheringOutcome.enough));
    }
  }

  void onComplete() => _finish(GatheringOutcome.complete);

  void _finish(GatheringOutcome outcome) {
    if (_done.isCompleted) return;
    finishedAt = _clock.elapsed;
    _cap.cancel();
    _grace?.cancel();
    _done.complete(outcome);
  }

  /// Releases the timers if the call ends while gathering.
  void dispose() {
    _cap.cancel();
    _grace?.cancel();
  }

  /// One log line: how long, why, and what was there. Counts and types only,
  /// never an address.
  String summary(GatheringOutcome outcome) {
    final first = firstUsableAt == null
        ? 'no usable candidate'
        : 'first usable at ${firstUsableAt!.inMilliseconds} ms';
    final counts = (types.entries.toList()
          ..sort((a, b) => a.key.compareTo(b.key)))
        .map((e) => '${e.key} ${e.value}')
        .join(', ');
    return 'ICE ${outcome.name} after ${finishedAt?.inMilliseconds} ms '
        '($first; ${counts.isEmpty ? 'no candidates' : counts})';
  }
}
