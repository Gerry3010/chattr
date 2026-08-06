// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert' show jsonDecode;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/logging/logger_service.dart';
import '../../../features/media/widgets/inline_link_video_player.dart';
import '../../../features/messages/message_links.dart';

/// Metadata extracted for a link preview.
class LinkPreviewData {
  final String? title;
  final String? imageUrl;

  /// Directly playable stream behind the link (Reddit HLS, og:video) — when
  /// set, the preview thumbnail opens the in-app popup player.
  final String? videoUrl;

  const LinkPreviewData({this.title, this.imageUrl, this.videoUrl});

  bool get hasImage => imageUrl != null && imageUrl!.isNotEmpty;
}

/// Link preview inside chat bubbles.
///
/// Renders a rich card (16:9 thumbnail + title + domain) when an image is
/// known — YouTube/Shorts thumbnails work on every platform without any
/// fetch — and falls back to the compact favicon+title row otherwise.
///
/// Metadata sources, in order:
///  * YouTube URLs: thumbnail derived from the video id (zero network).
///  * Native platforms: direct page fetch, og:title/og:image extraction.
///  * Web (CORS-blocked) and native fetch failures: the `link-preview`
///    edge function (server-side fetch with a browser UA — also the only
///    reliable way to preview Reddit, which rejects non-browser agents).
class CompactLinkPreview extends StatelessWidget {
  final String url;

  /// Base text color of the surrounding bubble; the preview derives its
  /// tint and title color from it so it works on both bubble variants.
  final Color textColor;

  /// Chat + message this preview belongs to — passed to an inline link video
  /// so it can dock back into this bubble from the floating PiP window.
  final String chatId;
  final String messageId;

  const CompactLinkPreview({
    super.key,
    required this.url,
    required this.textColor,
    required this.chatId,
    required this.messageId,
  });

  /// Previews by URL, cached as futures so each URL is resolved at most once
  /// per session (in-flight fetches are deduped too).
  static final Map<String, Future<LinkPreviewData>> _previewCache = {};

  static Future<LinkPreviewData> _fetchPreview(Uri uri) {
    return _previewCache.putIfAbsent(uri.toString(), () async {
      final youtubeThumb = _youtubeThumbnail(uri);

      // Page metadata: direct fetch on native (YouTube via its public oEmbed
      // endpoint — plain page fetches hit consent walls), edge function on
      // web (CORS), for Reddit (bot-gated; only the server-side post-JSON
      // lookup yields the playable video URL), or when the direct fetch
      // yields nothing.
      LinkPreviewData page = const LinkPreviewData();
      if (!kIsWeb && !isRedditUrl(uri)) {
        page = youtubeThumb != null
            ? await _fetchYoutubeOembed(uri)
            : await _fetchDirect(uri);
      }
      if (page.title == null && !page.hasImage) {
        page = await _fetchViaEdgeFunction(uri);
      }

      return LinkPreviewData(
        title: page.title,
        imageUrl: youtubeThumb ?? page.imageUrl,
        videoUrl: redditHlsFromDirectLink(uri) ?? page.videoUrl,
      );
    });
  }

  /// YouTube (incl. Shorts / youtu.be / m.youtube) thumbnails are derivable
  /// from the video id — a plain image URL that even the web build can show.
  static String? _youtubeThumbnail(Uri uri) {
    final id = youtubeVideoId(uri);
    if (id == null) return null;
    return 'https://img.youtube.com/vi/$id/hqdefault.jpg';
  }

  static Future<LinkPreviewData> _fetchYoutubeOembed(Uri uri) async {
    try {
      final res = await http
          .get(Uri.parse(
            'https://www.youtube.com/oembed?url=${Uri.encodeComponent(uri.toString())}&format=json',
          ))
          .timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) return const LinkPreviewData();
      final data = jsonDecode(res.body);
      if (data is! Map) return const LinkPreviewData();
      return LinkPreviewData(
        title: data['title'] as String?,
        imageUrl: data['thumbnail_url'] as String?,
      );
    } catch (e) {
      logger.debug('YouTube oEmbed fetch failed for $uri: $e');
      return const LinkPreviewData();
    }
  }

  static Future<LinkPreviewData> _fetchDirect(Uri uri) async {
    try {
      final res = await http.get(uri, headers: {
        // Some sites (e.g. Reddit) reject non-browser agents.
        'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/126.0 Safari/537.36',
        'Accept': 'text/html',
      }).timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) return const LinkPreviewData();
      return _parseHtml(res.body, uri);
    } catch (e) {
      logger.debug('Direct link preview fetch failed for $uri: $e');
      return const LinkPreviewData();
    }
  }

  static Future<LinkPreviewData> _fetchViaEdgeFunction(Uri uri) async {
    try {
      final res = await Supabase.instance.client.functions.invoke(
        'link-preview',
        method: HttpMethod.get,
        queryParameters: {'url': uri.toString()},
      );
      final data = res.data;
      if (data is! Map) return const LinkPreviewData();
      return LinkPreviewData(
        title: data['title'] as String?,
        imageUrl: data['image'] as String?,
        videoUrl: data['video'] as String?,
      );
    } catch (e) {
      logger.debug('Edge link preview failed for $uri: $e');
      return const LinkPreviewData();
    }
  }

  static LinkPreviewData _parseHtml(String html, Uri base) {
    final title = _meta(html, 'og:title') ??
        RegExp('<title[^>]*>([^<]*)</title>', caseSensitive: false)
            .firstMatch(html)
            ?.group(1)
            ?.trim();
    var image = _meta(html, 'og:image') ?? _meta(html, 'twitter:image');
    if (image != null) {
      // Resolve relative/protocol-relative image URLs against the page.
      image = Uri.tryParse(image)?.hasScheme == true
          ? image
          : base.resolve(image).toString();
    }
    return LinkPreviewData(
      title: title == null ? null : _decodeEntities(title),
      imageUrl: image,
    );
  }

  static String? _meta(String html, String property) {
    // Both attribute orders occur in the wild.
    final patterns = [
      RegExp(
        '<meta[^>]+(?:property|name)=["\']$property["\'][^>]+content=["\']([^"\']+)',
        caseSensitive: false,
      ),
      RegExp(
        '<meta[^>]+content=["\']([^"\']+)["\'][^>]+(?:property|name)=["\']$property["\']',
        caseSensitive: false,
      ),
    ];
    for (final re in patterns) {
      final m = re.firstMatch(html);
      if (m != null) return _decodeEntities(m.group(1)!.trim());
    }
    return null;
  }

  static String _decodeEntities(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&nbsp;', ' ');

  @override
  Widget build(BuildContext context) {
    final uri = normalizeUrl(url);
    if (uri == null) return const SizedBox.shrink();

    return FutureBuilder<LinkPreviewData>(
      future: _fetchPreview(uri),
      builder: (context, snapshot) {
        final data = snapshot.data ?? const LinkPreviewData();
        final title = (data.title?.trim().isNotEmpty ?? false)
            ? data.title!.trim()
            : uri.host;

        if (!data.hasImage) {
          return _compactRow(context, uri, title);
        }
        return _richCard(context, uri, title, data.imageUrl!, data.videoUrl);
      },
    );
  }

  /// Rich card: 16:9 thumbnail above title + domain. Falls back to the
  /// compact row if the image fails to load (dead og:image, web CORS).
  ///
  /// For playable links (YouTube, resolved Reddit/og videos) the thumbnail
  /// carries a play badge and opens the in-app popup player; the title/domain
  /// strip keeps opening the link externally. Non-playable cards behave like
  /// before (whole card opens the link).
  Widget _richCard(
    BuildContext context,
    Uri uri,
    String title,
    String imageUrl,
    String? videoUrl,
  ) {
    final mutedColor = textColor.withValues(alpha: 0.7);
    // Playable links play INLINE in the bubble: a resolved stream (Reddit HLS /
    // og:video) via media_kit (+ PiP + dock-back), YouTube via the iframe
    // player. Non-playable cards just open externally.
    final isStream = videoUrl != null;
    final ytId = isStream ? null : youtubeVideoId(uri);
    final ytPlayable = ytId != null && youtubeInlineSupported;
    final playable = isStream || ytPlayable;

    void openLink() => launchUrl(uri, mode: LaunchMode.externalApplication);

    Widget thumbnail = AspectRatio(
      aspectRatio: 16 / 9,
      child: Image.network(
        imageUrl,
        fit: BoxFit.cover,
        // CanvasKit needs CORS to decode network images; a plain
        // <img> element usually renders them regardless.
        webHtmlElementStrategy: WebHtmlElementStrategy.fallback,
        errorBuilder: (_, _, _) => ColoredBox(
          color: textColor.withValues(alpha: 0.06),
          child: Center(
            child: Icon(Icons.link, size: 28, color: mutedColor),
          ),
        ),
      ),
    );
    // Both inline players bring their own poster (thumbnail + play badge) and
    // handle playback (+ PiP for streams) internally.
    if (isStream) {
      thumbnail = InlineLinkVideoPlayer.stream(
        streamUrl: videoUrl,
        thumbnailUrl: imageUrl,
        chatId: chatId,
        messageId: messageId,
        textColor: textColor,
      );
    } else if (ytPlayable) {
      thumbnail = InlineLinkVideoPlayer.youtube(
        youtubeId: ytId,
        vertical: isYoutubeShorts(uri),
        thumbnailUrl: imageUrl,
        chatId: chatId,
        messageId: messageId,
        textColor: textColor,
      );
    }

    Widget titleStrip = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: textColor,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            uri.host,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: mutedColor, fontSize: 11),
          ),
        ],
      ),
    );
    if (playable) {
      titleStrip = InkWell(onTap: openLink, child: titleStrip);
    }

    final card = Container(
      decoration: BoxDecoration(
        color: textColor.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [thumbnail, titleStrip],
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: playable
          ? card
          : InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: openLink,
              child: card,
            ),
    );
  }

  /// The original compact favicon + title row.
  Widget _compactRow(BuildContext context, Uri uri, String title) {
    final faviconUrl = '${uri.scheme}://${uri.host}/favicon.ico';
    final mutedColor = textColor.withValues(alpha: 0.7);

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => launchUrl(uri, mode: LaunchMode.externalApplication),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: textColor.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.network(
                faviconUrl,
                width: 18,
                height: 18,
                webHtmlElementStrategy: WebHtmlElementStrategy.fallback,
                errorBuilder: (_, _, _) =>
                    Icon(Icons.link, size: 18, color: mutedColor),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: textColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
