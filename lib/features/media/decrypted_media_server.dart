// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../../core/logging/logger_service.dart';
import '../../core/security/message_encryption_service.dart';
import 'media_attachment.dart';
import 'media_compression.dart';
import 'media_repository.dart';

/// Delivers an encrypted medium to the player **piece by piece**, instead of
/// downloading, decrypting and writing it to disk in full beforehand.
///
/// **Why it is needed.** Until now the player only opened once the file lay
/// fully decrypted on disk — with an 80 MB video that is several seconds in
/// which nothing happens. That is exactly what "videos buffer" means: not the
/// stalling *during* playback (that was software decoding) but the wait
/// *before* it.
///
/// **Why this works at all — and only here.** A chunked medium consists of 6 MB
/// blocks, **each of which carries its own checksum**. A block can therefore be
/// verified on its own, and what is verified may be played. A single object, by
/// contrast, is ONE AES-GCM ciphertext whose checksum sits at the end: whoever
/// plays part of it earlier displays unverified bytes — and thereby loses
/// exactly the protection that catches a tampering server. For single objects
/// this server therefore still loads everything before handing out the first
/// byte. The difference is not a convenience trade-off but the reason blocks
/// exist.
///
/// **A side benefit, almost the larger one:** **no decrypted video file** comes
/// into being in the temp directory any more. Until now 80 MB of plaintext lay
/// there until the player closed — the one place a video lay unencrypted on the
/// device.
///
/// **Safeguards.** The server listens exclusively on `127.0.0.1` on a port
/// assigned by the operating system, requires a random path of 32 bytes and
/// answers everything else with 404. It lives only as long as the player. On
/// Android other apps can in principle reach loopback ports — hence the
/// unguessable path and the short lifetime, rather than relying on "it's only
/// local".
class DecryptedMediaServer {
  DecryptedMediaServer._(this._server, this._token, this._att, this._repo,
      this._svc);

  final HttpServer _server;
  final String _token;
  final MediaAttachment _att;
  final MediaRepository _repo;
  final MessageEncryptionService _svc;

  /// Decrypted blocks that were needed most recently. Kept small: every entry
  /// is 6 MB, and on the iPhone the limit is 90 MB.
  final _cache = <int, Uint8List>{};
  static const int _cacheChunks = 4;

  /// Blocks that must NOT be evicted: the first and the last.
  ///
  /// **Why those of all things.** An MP4 often carries its table of contents
  /// (`moov`) at the END — whoever did not write it with "faststart" forces
  /// every player to jump to the end of the file before the first frame and
  /// back to the beginning afterwards. Measured on the device: three
  /// connections, ~3.8 seconds to the first decoded frame, although hardly any
  /// compute was involved. Fetching these two blocks right at the start and
  /// then holding on to them serves exactly that jump from memory instead of
  /// twice over the network.
  final _pinned = <int>{};

  /// Requests in flight, so a prefetch does not load twice.
  final _inflight = <int, Future<Uint8List>>{};

  /// Single objects only: the one fully verified plaintext.
  Uint8List? _whole;

  bool _closed = false;

  /// How many blocks are fetched ahead while one is being delivered.
  static const int lookahead = 2;

  /// The address the player opens.
  String get uri => 'http://127.0.0.1:${_server.port}/$_token';

  /// Total length of the plaintext — what the player sees as the file size.
  int get _length => _att.size;

  int get _chunkSize => _att.chunkSize ?? MediaRepository.chunkSizeBytes;

  static Future<DecryptedMediaServer> start({
    required MediaAttachment attachment,
    required MediaRepository repo,
    required MessageEncryptionService svc,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final rnd = Random.secure();
    final token = base64Url
        .encode(List<int>.generate(24, (_) => rnd.nextInt(256)))
        .replaceAll('=', '');
    final self = DecryptedMediaServer._(server, token, attachment, repo, svc);
    server.listen(self._handle, onError: (Object e) {
      logger.debug('Medien-Server: $e', tag: 'DecryptedMediaServer');
    });
    self._primeEnds();
    return self;
  }

  /// Prefetches the beginning AND the end before the player even asks — the
  /// jump to the end of the file comes reliably with MP4, so we do not wait for
  /// it.
  void _primeEnds() {
    if (!_att.isChunked) return;
    final count = _att.chunkCount!;
    for (final i in {0, count - 1}) {
      _pinned.add(i);
      if (_cache.containsKey(i) || _inflight.containsKey(i)) continue;
      final f = _fetchChunk(i, count);
      f.ignore();
      _inflight[i] = f;
    }
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      if (req.uri.path != '/$_token') {
        res.statusCode = HttpStatus.notFound;
        await res.close();
        return;
      }
      res.headers
        ..set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..set(HttpHeaders.contentTypeHeader, _att.mime)
        // A cache would be pointless and unwanted here: the address lives only
        // for this one playback.
        ..set(HttpHeaders.cacheControlHeader, 'no-store');

      final (start, end) = _parseRange(req.headers.value(HttpHeaders.rangeHeader));
      if (start >= _length) {
        res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$_length');
        await res.close();
        return;
      }
      final last = end ?? (_length - 1);
      res.statusCode = req.headers.value(HttpHeaders.rangeHeader) == null
          ? HttpStatus.ok
          : HttpStatus.partialContent;
      if (res.statusCode == HttpStatus.partialContent) {
        res.headers.set(
            HttpHeaders.contentRangeHeader, 'bytes $start-$last/$_length');
      }
      res.headers.set(HttpHeaders.contentLengthHeader, '${last - start + 1}');

      if (req.method == 'HEAD') {
        await res.close();
        return;
      }
      await _write(res, start, last);
      await res.close();
    } catch (e) {
      // An abort by the player (seeking elsewhere closes the connection) is the
      // normal case, not an error.
      logger.debug('Medien-Server beendet die Antwort: $e',
          tag: 'DecryptedMediaServer');
      try {
        await res.close();
      } catch (_) {}
    }
  }

  Future<void> _write(HttpResponse res, int start, int last) async {
    if (!_att.isChunked) {
      final all = await _wholePlaintext();
      res.add(all.sublist(start, min(last + 1, all.length)));
      return;
    }
    final count = _att.chunkCount!;
    var pos = start;
    while (pos <= last && !_closed) {
      final index = pos ~/ _chunkSize;
      if (index >= count) break;
      // Prefetch: while this block is being delivered, the next ones are
      // already on their way. Without it the player waits afresh at every block
      // boundary.
      _prefetch(index + 1, count);
      final chunk = await _chunkAt(index);
      final chunkStart = index * _chunkSize;
      final from = pos - chunkStart;
      final to = min(chunk.length, last - chunkStart + 1);
      if (to <= from) break;
      res.add(chunk.sublist(from, to));
      // Let it flow rather than piling everything up in memory — otherwise the
      // point of the exercise would be gone again.
      await res.flush();
      pos = chunkStart + to;
    }
  }

  void _prefetch(int from, int count) {
    for (var i = from; i < min(from + lookahead, count); i++) {
      if (_cache.containsKey(i) || _inflight.containsKey(i)) continue;
      final f = _fetchChunk(i, count);
      // Attach a silent listener at once: if a prefetched block fails while we
      // are still delivering an earlier one, its error would have no taker at
      // that moment — and Dart would report it as unhandled, although the real
      // error arrives properly straight afterwards.
      f.ignore();
      _inflight[i] = f;
    }
  }

  Future<Uint8List> _chunkAt(int index) async {
    final cached = _cache[index];
    if (cached != null) return cached;
    final running = _inflight[index];
    if (running != null) return running;
    final f = _fetchChunk(index, _att.chunkCount!);
    _inflight[index] = f;
    return f;
  }

  Future<Uint8List> _fetchChunk(int index, int count) async {
    try {
      final coords = _att.chunkCoordinates;
      if (coords == null) {
        throw StateError('chunked media path is not a chunk prefix: ${_att.path}');
      }
      final blob = await _repo.downloadEncrypted(_att.chunkPath(index));
      final plain = await _svc.decryptChunk(
        blob,
        base64Decode(_att.keyB64),
        aad: MessageEncryptionService.mediaChunkAad(
            coords.messageId, coords.attIndex, index, count),
      );
      _remember(index, plain);
      // Everything there? Then tell the server this recipient has the file
      // (cleanup signal 00056) — exactly as on the previous path.
      if (_cacheHighWater >= count - 1) signalMediaDownloaded(_repo, _att);
      return plain;
    } finally {
      _inflight.remove(index);
    }
  }

  int _cacheHighWater = -1;

  void _remember(int index, Uint8List plain) {
    if (index > _cacheHighWater) _cacheHighWater = index;
    _cache[index] = plain;
    while (_cache.length > _cacheChunks) {
      // Sacrifice the first evictable entry — the pinned ones stay.
      final opfer = _cache.keys.cast<int?>().firstWhere(
            (k) => !_pinned.contains(k),
            orElse: () => null,
          );
      if (opfer == null) break;
      _cache.remove(opfer);
    }
  }

  Future<Uint8List> _wholePlaintext() async {
    final have = _whole;
    if (have != null) return have;
    // Single object: ONE ciphertext, ONE checksum at the end. Handing anything
    // out before that would mean displaying unverified data.
    final blob = await _repo.downloadEncrypted(_att.path);
    var plain = await _svc.decryptBytes(blob, base64Decode(_att.keyB64));
    if (_att.compression == MediaCompression.gzip) {
      plain = await MediaCompression.decompress(plain,
          maxBytes: MediaRepository.maxUploadBytes);
    }
    _whole = plain;
    signalMediaDownloaded(_repo, _att);
    return plain;
  }

  (int, int?) _parseRange(String? header) {
    if (header == null || !header.startsWith('bytes=')) return (0, null);
    final spec = header.substring(6).split(',').first.trim();
    final parts = spec.split('-');
    if (parts.length != 2) return (0, null);
    final startText = parts[0].trim();
    final endText = parts[1].trim();
    if (startText.isEmpty) {
      // „bytes=-500" = die letzten 500 Byte.
      final tail = int.tryParse(endText);
      if (tail == null || tail <= 0) return (0, null);
      return (max(0, _length - tail), _length - 1);
    }
    final start = int.tryParse(startText) ?? 0;
    final end = endText.isEmpty ? null : int.tryParse(endText);
    return (start, end == null ? null : min(end, _length - 1));
  }

  Future<void> dispose() async {
    _closed = true;
    _cache.clear();
    _whole = null;
    try {
      await _server.close(force: true);
    } catch (_) {
      // Best effort — a dangling port costs nothing, a crash does.
    }
  }
}
