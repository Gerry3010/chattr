// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:typed_data';

/// One outgoing file picked for sending. Its plaintext lives EITHER in memory
/// ([bytes], small/web/camera/edited) OR on disk ([sourcePath], large native
/// files that must be streamed/chunked so the whole thing never sits in RAM —
/// backlog large-file-chunking). Exactly one of the two is set. Batches of these
/// become a [MediaAlbum] (#109); a single file is just a 1-element list.
class OutgoingMedia {
  /// In-memory plaintext, or null when the source is a file path.
  final Uint8List? bytes;

  /// On-disk plaintext path (streamed in chunks), or null for in-memory sources.
  final String? sourcePath;

  final String fileName;
  final String mime;

  /// Plaintext size in bytes (known up-front for both sources — decides whether
  /// this item is chunked and drives size checks without reading the file).
  final int size;

  const OutgoingMedia._({
    this.bytes,
    this.sourcePath,
    required this.fileName,
    required this.mime,
    required this.size,
  });

  /// An in-memory source (small files, web, camera capture, edited output).
  factory OutgoingMedia.bytes(
    Uint8List bytes, {
    required String fileName,
    required String mime,
  }) =>
      OutgoingMedia._(
        bytes: bytes,
        fileName: fileName,
        mime: mime,
        size: bytes.length,
      );

  /// An on-disk source streamed from [path] (large native files → chunked send).
  factory OutgoingMedia.file(
    String path, {
    required int size,
    required String fileName,
    required String mime,
  }) =>
      OutgoingMedia._(
        sourcePath: path,
        fileName: fileName,
        mime: mime,
        size: size,
      );
}

/// Best-effort MIME type from a file extension (used when sending media).
String mimeForExtension(String? extension) {
  switch ((extension ?? '').toLowerCase()) {
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'png':
      return 'image/png';
    case 'gif':
      return 'image/gif';
    case 'webp':
      return 'image/webp';
    case 'heic':
      return 'image/heic';
    case 'mp4':
      return 'video/mp4';
    case 'mov':
      return 'video/quicktime';
    case 'webm':
      return 'video/webm';
    case 'mkv':
      return 'video/x-matroska';
    case 'mp3':
      return 'audio/mpeg';
    case 'm4a':
      return 'audio/mp4';
    case 'wav':
      return 'audio/wav';
    case 'ogg':
      return 'audio/ogg';
    case 'pdf':
      return 'application/pdf';
    case 'zip':
      return 'application/zip';
    case 'gz':
      return 'application/gzip';
    case '7z':
      return 'application/x-7z-compressed';
    case 'rar':
      return 'application/vnd.rar';
    case 'txt':
      return 'text/plain';
    case 'json':
      return 'application/json';
    case 'md':
      return 'text/markdown';
    default:
      return 'application/octet-stream';
  }
}

/// Kind of media, used to pick the renderer (and a sensible default icon).
enum MediaType {
  image,
  video,
  audio,
  file;

  static MediaType fromMime(String mime) {
    if (mime.startsWith('image/')) return MediaType.image;
    if (mime.startsWith('video/')) return MediaType.video;
    if (mime.startsWith('audio/')) return MediaType.audio;
    return MediaType.file;
  }

  static MediaType fromName(String name) {
    switch (name.toLowerCase()) {
      case 'image':
        return MediaType.image;
      case 'video':
        return MediaType.video;
      case 'audio':
        return MediaType.audio;
      default:
        return MediaType.file;
    }
  }

  /// The coarse category tag written onto the storage object as
  /// `x-media-kind` (see [MediaRepository.uploadEncrypted]).
  ///
  /// Deliberately NOT the enum name: `file` is an app-side rendering concept,
  /// while the operator dashboard groups by image/video/audio/**other** — and
  /// its `metrics_media_by_kind` chart has a colour for `other`, not for `file`.
  String get storageKind => this == MediaType.file ? 'other' : name;
}

/// Describes one encrypted media attachment. This is the plaintext that lives
/// **inside** the per-recipient message envelope (so the AES media key is only
/// ever readable by chat members). The encrypted file bytes themselves live in
/// the private `media` storage bucket at [path].
class MediaAttachment {
  /// Marker key so we can tell a media envelope from a plain text message.
  static const String marker = '_chattr_media';

  final MediaType mediaType;
  final String name; // original file name
  final String mime; // content type
  final int size; // plaintext size in bytes
  final String path; // storage object path: <chatId>/<messageId>/<file>.enc
  final String keyB64; // base64 AES-256 media key

  /// Codec applied to the plaintext BEFORE encryption ('gzip'), null = raw.
  /// Old clients ignore unknown JSON keys, so this is additive.
  final String? compression;

  /// CHUNKED media (backlog large-file-chunking): number of independently
  /// AES-GCM-encrypted chunks the file was split into, and the plaintext
  /// [chunkSize] of each (the last chunk may be smaller). Null ⇒ single-object
  /// media (the legacy path). When set, [path] is a PREFIX and the chunk objects
  /// live at `"$path-chunk-<i>.enc"` for i in 0..chunkCount-1. Additive keys →
  /// old clients ignore them (and can't render the item, degrading gracefully).
  final int? chunkCount;
  final int? chunkSize;

  /// Intrinsic pixel dimensions of an image/video, sent so the recipient can
  /// reserve the correct box BEFORE the bytes download → no scroll-flicker as
  /// the placeholder grows to the loaded size (#9). Additive & optional: absent
  /// for non-visual media, older senders, or when they couldn't be determined
  /// (recipient falls back to the pre-#9 placeholder behaviour).
  final int? width;
  final int? height;

  /// VIDEO cover frame: a small JPEG poster the sender generated + encrypted +
  /// uploaded as its OWN media object ([thumbPath], under the same
  /// `<chatId>/<messageId>/` folder so the messageId-keyed reaper groups it),
  /// with its own AES key ([thumbKey], base64). The recipient decrypts just this
  /// tiny blob to show a real thumbnail behind the play button instead of a
  /// black box — WITHOUT downloading the whole (possibly chunked) video. Additive
  /// & optional: absent for non-video media, non-native/older senders, or when
  /// generation failed (recipient falls back to the plain black poster).
  final String? thumbPath;
  final String? thumbKey;

  /// Transient: local path of the decrypted file once downloaded (cache).
  final String? localPath;

  bool get isChunked => chunkCount != null;

  /// Intrinsic aspect ratio (w/h) when both dimensions are known and valid,
  /// else null. Drives the placeholder's [AspectRatio] so it matches the image.
  double? get aspectRatio =>
      (width != null && height != null && width! > 0 && height! > 0)
          ? width! / height!
          : null;

  const MediaAttachment({
    required this.mediaType,
    required this.name,
    required this.mime,
    required this.size,
    required this.path,
    required this.keyB64,
    this.compression,
    this.chunkCount,
    this.chunkSize,
    this.width,
    this.height,
    this.thumbPath,
    this.thumbKey,
    this.localPath,
  });

  MediaAttachment copyWith({String? localPath}) => MediaAttachment(
        mediaType: mediaType,
        name: name,
        mime: mime,
        size: size,
        path: path,
        keyB64: keyB64,
        compression: compression,
        chunkCount: chunkCount,
        chunkSize: chunkSize,
        width: width,
        height: height,
        thumbPath: thumbPath,
        thumbKey: thumbKey,
        localPath: localPath ?? this.localPath,
      );

  /// Storage object path of chunk [index] for a chunked attachment.
  String chunkPath(int index) => '$path-chunk-$index.enc';

  /// The `messageId` + album `attIndex` a chunked item's per-chunk AAD binds to,
  /// recovered from the prefix [path] `<chatId>/<messageId>/media-<attIndex>`
  /// (the sender's `chunkPrefixPath`). Needed to rebuild `mediaChunkAad` on
  /// decrypt. Null if [path] isn't a chunk prefix.
  ({String messageId, int attIndex})? get chunkCoordinates {
    final parts = path.split('/');
    if (parts.length < 3) return null;
    final m = RegExp(r'^media-(\d+)$').firstMatch(parts[parts.length - 1]);
    if (m == null) return null;
    return (messageId: parts[parts.length - 2], attIndex: int.parse(m.group(1)!));
  }

  /// The `<chatId>/<messageId>` this blob lives under (the first two path
  /// segments — same for single-object and chunk-prefix paths). Used to signal a
  /// per-recipient media download (00056). Null if [path] isn't in that layout.
  ({String chatId, String messageId})? get storageIds {
    final parts = path.split('/');
    if (parts.length < 2 || parts[0].isEmpty || parts[1].isEmpty) return null;
    return (chatId: parts[0], messageId: parts[1]);
  }

  /// Per-item JSON WITHOUT the envelope [marker]. Used both as an entry in the
  /// album's `items[]` array and (with the marker prepended by [MediaAlbum]) as
  /// the top-level item[0] fallback that old single-media clients read.
  Map<String, dynamic> toItemJson() => {
        'media_type': mediaType.name,
        'name': name,
        'mime': mime,
        'size': size,
        'path': path,
        'key': keyB64,
        // Omitted when null so uncompressed envelopes stay byte-identical to
        // pre-compression clients.
        if (compression != null) 'compression': compression,
        // Additive chunk metadata; absent for legacy single-object media.
        if (chunkCount != null) 'chunk_count': chunkCount,
        if (chunkSize != null) 'chunk_size': chunkSize,
        // Additive intrinsic dimensions (#9); omitted when unknown so envelopes
        // without them stay byte-identical to pre-#9 clients.
        if (width != null) 'w': width,
        if (height != null) 'h': height,
        // Additive video cover-frame pointer; omitted for non-video / when no
        // thumbnail was generated.
        if (thumbPath != null) 'tp': thumbPath,
        if (thumbKey != null) 'tk': thumbKey,
      };

  static MediaAttachment fromJson(Map<String, dynamic> json) => MediaAttachment(
        mediaType: MediaType.fromName(json['media_type'] as String? ?? 'file'),
        name: json['name'] as String? ?? 'file',
        mime: json['mime'] as String? ?? 'application/octet-stream',
        size: (json['size'] as num?)?.toInt() ?? 0,
        path: json['path'] as String,
        keyB64: json['key'] as String,
        compression: json['compression'] as String?,
        chunkCount: (json['chunk_count'] as num?)?.toInt(),
        chunkSize: (json['chunk_size'] as num?)?.toInt(),
        width: (json['w'] as num?)?.toInt(),
        height: (json['h'] as num?)?.toInt(),
        thumbPath: json['tp'] as String?,
        thumbKey: json['tk'] as String?,
      );

  /// Convenience: encode this single attachment as a one-item album envelope —
  /// byte-identical to a legacy single-media message. Multi-item sends build a
  /// [MediaAlbum] directly.
  String encode() => MediaAlbum(items: [this]).encode();

  @override
  bool operator ==(Object other) =>
      other is MediaAttachment &&
      other.path == path &&
      other.keyB64 == keyB64 &&
      other.localPath == localPath;

  @override
  int get hashCode => Object.hash(path, keyB64, localPath);

  /// Convenience shim: the FIRST attachment of the album carried by
  /// [decryptedBody], or null if the body isn't a media envelope. Call sites
  /// that only need "is this media / the first item" keep using this; multi-item
  /// aware sites use [MediaAlbum.tryParse].
  static MediaAttachment? tryParse(String? decryptedBody) =>
      MediaAlbum.tryParse(decryptedBody)?.items.first;
}

/// Returns [body] with its caption set to [caption] (trimmed; empty removes
/// it), or null when [body] is not a media envelope.
///
/// Edits the raw JSON instead of going through [MediaAlbum.toJson]: a round
/// trip through the model keeps only the fields this build knows, and an
/// envelope from a newer client would silently lose the rest on a mere
/// caption fix. Only `caption` changes; path, key and every other field stay
/// byte for byte.
String? replaceCaption(String body, String caption) {
  if (MediaAlbum.tryParse(body) == null) return null;
  final json = jsonDecode(body) as Map<String, dynamic>;
  final text = caption.trim();
  if (text.isEmpty) {
    json.remove('caption');
  } else {
    json['caption'] = text;
  }
  return jsonEncode(json);
}

/// A media message envelope: one or more [MediaAttachment]s plus an optional
/// album-wide text [caption] (#110). This is the plaintext that gets
/// per-recipient hybrid-encrypted as the message body.
///
/// **Backward compatibility (#109):** item[0]'s fields are ALSO written at the
/// top level next to the marker, so a pre-#109 client (which reads a scalar
/// `path`/`key`) renders the first item and silently ignores the `items` array.
/// A single-item album omits `items` entirely, making its encoding byte-for-byte
/// identical to what pre-#109 clients produced (plus the optional caption).
class MediaAlbum {
  final List<MediaAttachment> items;

  /// Album-wide caption (#110), shown once below the whole album.
  final String? caption;

  const MediaAlbum({required this.items, this.caption});

  MediaAttachment get first => items.first;
  bool get isAlbum => items.length > 1;

  // The one-line preview label lives in media_preview_label.dart, not here:
  // it needs translations, and this file is the pure envelope model that the
  // crypto tests parse without a locale loaded.

  Map<String, dynamic> toJson() => {
        MediaAttachment.marker: 1,
        // item[0] scalars at the top level → old-client fallback.
        ...items.first.toItemJson(),
        if (caption != null && caption!.isNotEmpty) 'caption': caption,
        // Only present for true albums; a single item stays byte-identical to a
        // pre-#109 envelope.
        if (items.length > 1)
          'items': [for (final it in items) it.toItemJson()],
      };

  /// Serialize to the envelope plaintext string.
  String encode() => jsonEncode(toJson());

  /// Parse a decrypted message body into a [MediaAlbum], or null if the body is
  /// a plain text message. New multi-item envelopes carry `items[]`; legacy
  /// single-item envelopes are read from the top-level scalars.
  static MediaAlbum? tryParse(String? decryptedBody) {
    if (decryptedBody == null || decryptedBody.isEmpty) return null;
    if (!decryptedBody.contains(MediaAttachment.marker)) return null;
    try {
      final json = jsonDecode(decryptedBody) as Map<String, dynamic>;
      if (json[MediaAttachment.marker] == null) return null;
      final raw = json['items'];
      final items = (raw is List && raw.isNotEmpty)
          ? [
              for (final e in raw)
                MediaAttachment.fromJson(e as Map<String, dynamic>)
            ]
          : [MediaAttachment.fromJson(json)];
      return MediaAlbum(items: items, caption: json['caption'] as String?);
    } catch (_) {
      return null;
    }
  }
}
