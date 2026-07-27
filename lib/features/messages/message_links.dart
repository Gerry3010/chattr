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

/// Pattern for splitting message text into text/link spans. Matches the same
/// URLs as [extractUrls] (trailing punctuation is handled by the callers via
/// [extractUrls]' trimming).
RegExp get urlPattern => _urlRegExp;

/// Parses [url] into a launchable [Uri], prefixing bare `www.` links with
/// https. Returns null when the value is not a usable absolute URL.
Uri? normalizeUrl(String url) {
  final withScheme =
      url.toLowerCase().startsWith('http') ? url : 'https://$url';
  final uri = Uri.tryParse(withScheme);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
  return uri;
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
