// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Title and image of a page, read from its HTML (CHAT-35).
///
/// The page belongs to whoever sent the link, so the parser must not be a way
/// to freeze the app. The old patterns ran `[^>]+…[^>]+` over the whole
/// document on the UI isolate and backtracked: 7.5 s for a 64 KiB page built
/// for it. Here every pattern is bounded: tags are cut out first with a
/// length limit, attributes are read inside one tag only, and the input is
/// capped at [maxHtmlChars]. Callers run it in `compute()` as well.
const int maxHtmlChars = 256 * 1024;

final RegExp _metaTag = RegExp(r'<meta\b[^>]{0,2048}>', caseSensitive: false);
final RegExp _attribute =
    RegExp(r'''([a-zA-Z:_-]{1,64})\s*=\s*(?:"([^"]{0,2048})"|'([^']{0,2048})')''');
final RegExp _title =
    RegExp(r'<title\b[^>]{0,256}>([^<]{0,1024})</title>', caseSensitive: false);

/// `(title, image)` from [html]; relative image URLs are resolved against
/// [base]. Pure and top-level, so it can run in `compute()`.
({String? title, String? image}) parseLinkPreviewHtml((String, String) job) {
  final (raw, baseUrl) = job;
  final html = raw.length > maxHtmlChars ? raw.substring(0, maxHtmlChars) : raw;
  final meta = <String, String>{};
  for (final tag in _metaTag.allMatches(html)) {
    final attrs = <String, String>{};
    for (final a in _attribute.allMatches(tag.group(0)!)) {
      attrs[a.group(1)!.toLowerCase()] = a.group(2) ?? a.group(3) ?? '';
    }
    final key = (attrs['property'] ?? attrs['name'])?.toLowerCase();
    final content = attrs['content'];
    if (key == null || content == null || content.trim().isEmpty) continue;
    meta.putIfAbsent(key, () => decodeHtmlEntities(content.trim()));
  }
  final title = meta['og:title'] ??
      _title.firstMatch(html)?.group(1)?.trim().let(decodeHtmlEntities);
  var image = meta['og:image'] ?? meta['twitter:image'];
  if (image != null && Uri.tryParse(image)?.hasScheme != true) {
    image = Uri.tryParse(baseUrl)?.resolve(image).toString();
  }
  return (title: title == null || title.isEmpty ? null : title, image: image);
}

String decodeHtmlEntities(String s) => s
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&apos;', "'")
    .replaceAll('&nbsp;', ' ');

extension _Let<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
