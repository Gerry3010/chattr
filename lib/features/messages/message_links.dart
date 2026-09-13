// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

/// URL detection for message text — used to route link-containing messages
/// through the custom bubble (compact link preview) instead of chatview's
/// built-in text bubble.
library;

final RegExp _urlRegExp = RegExp(
  r'(https?://[^\s<>()]+|www\.[^\s<>()]+\.[^\s<>()]+)',
  caseSensitive: false,
);

/// A bare e-mail address in running text.
///
/// Deliberately strict: at least one dot before a purely alphabetic ending.
/// Otherwise the pattern would swallow things like `@gerry` (a mention) or
/// `preis@stueck`, turning a word into a button that tears open a mail app.
final RegExp _emailRegExp = RegExp(
  r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,}",
);

/// What becomes tappable in a text at all: URLs first, then e-mails.
///
/// **The order is the whole logic.** An address like `https://user@host/path`
/// carries an `@` of its own — were the e-mail form first, it would rip a piece
/// out of the middle of the link and leave half a broken reference behind. The
/// URL branch matches earlier in the text and therefore wins.
final RegExp _linkTokenRegExp = RegExp(
  '(?:${_urlRegExp.pattern}|${_emailRegExp.pattern})',
  caseSensitive: false,
);

/// Extracts all http(s)/www URLs from [text], with trailing sentence
/// punctuation stripped ("check https://x.dev." should not link the dot).
List<String> extractUrls(String? text) {
  if (text == null || text.isEmpty) return const [];
  return _urlRegExp
      .allMatches(text)
      .map((m) => m.group(0)!.replaceFirst(RegExp(r'[.,;:!?]+$'), ''))
      .where((url) => url.isNotEmpty)
      .toList();
}

/// Every e-mail address in [text] — the counterpart to [extractUrls], so that a
/// message whose only tappable thing is an address reaches the bubble that
/// actually links at all.
List<String> extractEmails(String? text) {
  if (text == null || text.isEmpty) return const [];
  // Blank out the URLs first: what sits inside `https://user@host/` is not a
  // mail address but part of the link.
  final ohneUrls = text.replaceAll(_urlRegExp, ' ');
  return _emailRegExp.allMatches(ohneUrls).map((m) => m.group(0)!).toList();
}

/// Pattern for splitting message text into text/link spans — URLs **and** bare
/// e-mail addresses. Both bubbles share this one expression so they cannot
/// drift apart.
RegExp get linkTokenPattern => _linkTokenRegExp;

/// Schemes a message is allowed to open.
///
/// An allowlist, not a blocklist: whatever is not named here stays ordinary
/// text instead of becoming a button whose effect depends on the platform
/// (`javascript:`, `intent:`, `file:` …).
const _erlaubteSchemata = {'http', 'https', 'mailto', 'tel'};

final RegExp _schemeAtStart = RegExp(r'^([A-Za-z][A-Za-z0-9+.\-]*):');

/// Parses [url] into a launchable [Uri], prefixing bare `www.` links with
/// https. Returns null when the value is not a usable absolute URL.
///
/// **`mailto:` and `tel:` pass through untouched.** Previously anything not
/// starting with `http` got an `https://` put in front —
/// `mailto:sebi@example.at` became `https://mailto:sebi@example.at`, which Dart
/// happily reads as host `example.at` with user info `mailto:sebi`. So the link
/// LOOKED right, was underlined and tappable, and then opened the browser on a
/// stranger's site instead of the mail app. A silent wrong turn is worse than
/// no link at all.
Uri? normalizeUrl(String url) {
  final raw = url.trim();
  if (raw.isEmpty) return null;

  final schema = _schemeAtStart.firstMatch(raw)?.group(1)?.toLowerCase();
  if (schema != null && !_erlaubteSchemata.contains(schema)) return null;

  if (schema == 'mailto' || schema == 'tel') {
    final uri = Uri.tryParse(raw);
    // `mailto:` allein ist kein Ziel.
    if (uri == null || uri.path.trim().isEmpty) return null;
    return uri;
  }

  // A bare address must be an e-mail address in its entirety — an `@` somewhere
  // in the text is explicitly not enough.
  if (schema == null && _istGanzEineMail(raw)) return Uri.parse('mailto:$raw');

  final withScheme = schema == null ? 'https://$raw' : raw;
  final uri = Uri.tryParse(withScheme);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
  return uri;
}

bool _istGanzEineMail(String value) {
  final m = _emailRegExp.matchAsPrefix(value);
  return m != null && m.end == value.length;
}

/// Extracts the YouTube video id from watch/shorts/live/embed/youtu.be URLs
/// (www./m. prefixes included). Null for anything else.
String? youtubeVideoId(Uri uri) {
  final host = uri.host.replaceFirst('www.', '').replaceFirst('m.', '');
  String? id;
  if (host == 'youtu.be') {
    id = uri.pathSegments.firstOrNull;
  } else if (host == 'youtube.com') {
    if (uri.path == '/watch') {
      id = uri.queryParameters['v'];
    } else if (uri.pathSegments.length >= 2 &&
        (uri.pathSegments.first == 'shorts' ||
            uri.pathSegments.first == 'embed' ||
            uri.pathSegments.first == 'live')) {
      id = uri.pathSegments[1];
    }
  }
  if (id == null || id.isEmpty || !RegExp(r'^[\w-]{6,}$').hasMatch(id)) {
    return null;
  }
  return id;
}

/// Whether [uri] is a YouTube Shorts link — Shorts are vertical, so the
/// popup player uses a 9:16 box instead of 16:9.
bool isYoutubeShorts(Uri uri) {
  final host = uri.host.replaceFirst('www.', '').replaceFirst('m.', '');
  return host == 'youtube.com' &&
      uri.pathSegments.isNotEmpty &&
      uri.pathSegments.first == 'shorts' &&
      youtubeVideoId(uri) != null;
}

/// Whether [uri] points at reddit — those previews always go through the
/// `link-preview` edge function (Reddit bot-gates plain fetches, and only the
/// server-side post-JSON lookup can surface the playable video URL).
bool isRedditUrl(Uri uri) {
  final host = uri.host.toLowerCase();
  return host == 'redd.it' ||
      host == 'reddit.com' ||
      host.endsWith('.reddit.com') ||
      host == 'v.redd.it';
}

/// Direct v.redd.it links carry the video id in the path — the HLS playlist
/// (video + audio) is derivable without any lookup.
String? redditHlsFromDirectLink(Uri uri) {
  if (uri.host.toLowerCase() != 'v.redd.it') return null;
  final id = uri.pathSegments.firstOrNull;
  if (id == null || !RegExp(r'^[a-z0-9]{8,}$').hasMatch(id)) return null;
  return 'https://v.redd.it/$id/HLSPlaylist.m3u8';
}

/// Start time from a YouTube link, in seconds — `null` when there is none.
///
/// YouTube writes the timestamp in several forms, and the app used to read
/// **none** of them: a link shared "from minute 3" still started at zero.
///   * `?t=90`      — bare seconds (youtu.be's "share from here" form)
///   * `?t=90s`
///   * `?t=1m30s` / `?t=1h2m3s` — the compound form
///   * `?start=90`  — the embedding parameter
///   * `#t=90` / `#t=1m30s` — the old form in the fragment
///
/// `HH:MM:SS` is not something YouTube itself produces, but it is read anyway:
/// links travel through notes and other tools, and understanding a `1:30` costs
/// three lines. Generous when reading, strict about the result — anything that
/// does not resolve cleanly yields `null`, and with it the start at zero as
/// before, never a guessed number.
int? youtubeStartSeconds(Uri uri) {
  if (youtubeVideoId(uri) == null) return null;
  final raw = uri.queryParameters['t'] ??
      uri.queryParameters['start'] ??
      _fragmentTimeToken(uri.fragment);
  final seconds = parseTimeToken(raw);
  // 0 means "from the top" — the player needs no instruction for that.
  return (seconds == null || seconds <= 0) ? null : seconds;
}

/// Pull `#t=90` out of the fragment (the old YouTube form).
String? _fragmentTimeToken(String fragment) {
  if (fragment.isEmpty) return null;
  final m = RegExp(r'(?:^|&)t=([^&]+)').firstMatch(fragment);
  return m?.group(1);
}

final RegExp _compoundTime = RegExp(
  r'^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s?)?$',
  caseSensitive: false,
);

/// One time token in seconds. Public because that is exactly where the test
/// attaches.
int? parseTimeToken(String? raw) {
  final token = raw?.trim().toLowerCase();
  if (token == null || token.isEmpty) return null;

  // Reine Ziffern: Sekunden.
  if (RegExp(r'^\d+$').hasMatch(token)) return int.tryParse(token);

  // HH:MM:SS or MM:SS — not from YouTube, but unambiguous.
  if (token.contains(':')) {
    final parts = token.split(':');
    if (parts.length > 3 || parts.any((t) => !RegExp(r'^\d+$').hasMatch(t))) {
      return null;
    }
    var sekunden = 0;
    for (final t in parts) {
      sekunden = sekunden * 60 + int.parse(t);
    }
    return sekunden;
  }

  final m = _compoundTime.firstMatch(token);
  // The expression allows every group to be empty — "all optional" means that
  // nonsense like `abc` does NOT match, but an empty match does. So at least
  // one group has to be filled.
  if (m == null ||
      (m.group(1) == null && m.group(2) == null && m.group(3) == null)) {
    return null;
  }
  return int.parse(m.group(1) ?? '0') * 3600 +
      int.parse(m.group(2) ?? '0') * 60 +
      int.parse(m.group(3) ?? '0');
}

/// The media kind behind a link, where the address already gives it away —
/// `null` for ordinary pages.
///
/// Why from the extension and not from the content type: a `HEAD` before every
/// preview would be one more request to a stranger's server for **every** link
/// in the history, so more given away, not less. The extension costs nothing
/// and is already at hand. It can be wrong; the price for that is a card that
/// does not play — not an error.
enum LinkMediaKind { image, video, audio }

const _bekannteEndungen = <String, LinkMediaKind>{
  'jpg': LinkMediaKind.image, 'jpeg': LinkMediaKind.image,
  'png': LinkMediaKind.image, 'gif': LinkMediaKind.image,
  'webp': LinkMediaKind.image, 'bmp': LinkMediaKind.image,
  'heic': LinkMediaKind.image, 'avif': LinkMediaKind.image,
  'mp4': LinkMediaKind.video, 'webm': LinkMediaKind.video,
  'mov': LinkMediaKind.video, 'm4v': LinkMediaKind.video,
  'mkv': LinkMediaKind.video,
  'mp3': LinkMediaKind.audio, 'm4a': LinkMediaKind.audio,
  'aac': LinkMediaKind.audio, 'ogg': LinkMediaKind.audio,
  'opus': LinkMediaKind.audio, 'wav': LinkMediaKind.audio,
  'flac': LinkMediaKind.audio,
};

/// The media kind behind [uri], from the file extension of the path.
LinkMediaKind? directMediaKind(Uri uri) {
  final path = uri.path.toLowerCase();
  final dot = path.lastIndexOf('.');
  if (dot < 0 || dot == path.length - 1) return null;
  return _bekannteEndungen[path.substring(dot + 1)];
}

/// The file name from the path — more useful as the title of a preview card
/// than the bare host name.
String? linkFileName(Uri uri) {
  final last = uri.pathSegments.isEmpty ? null : uri.pathSegments.last;
  return (last == null || last.isEmpty) ? null : Uri.decodeComponent(last);
}
