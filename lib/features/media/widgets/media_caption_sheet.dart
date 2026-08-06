// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../core/logging/logger_service.dart';
import '../../../core/navigation/app_page_route.dart';
import '../editing/media_edit_launcher.dart';
import '../editing/video_trim_screen.dart' show TrimSettings;
import '../media_attachment.dart';
import '../media_repository.dart';
import '../video_render_config.dart';
import '../video_source.dart';
import 'attach_menu.dart' show maxAlbumItems, pickMoreMedia;
import 'file_type_visuals.dart';

/// Result of the caption sheet: the (possibly edited) items and the shared
/// caption. `null` return from [showMediaCaptionSheet] means the user backed out.
typedef CaptionSheetResult = ({List<OutgoingMedia> items, String caption});

/// Full-screen preview + caption composer + per-item editor entry point, shown
/// between picking media and sending it (#110 caption, #109 album, media-editing
/// round). Previews the selected item (albums get a thumbnail strip to switch),
/// offers an Edit button for editable items (image everywhere, video on mobile),
/// and returns the working item list plus the typed caption on send.
///
/// Returns the {items, caption} on send (empty caption string = send without a
/// caption) or `null` when the user backs out (send aborted).
Future<CaptionSheetResult?> showMediaCaptionSheet(
  BuildContext context, {
  required List<OutgoingMedia> items,
  String? initialText,
}) {
  return Navigator.of(context).push<CaptionSheetResult>(
    appPageRoute<CaptionSheetResult>(
      fullscreenDialog: true,
      builder: (_) => _MediaCaptionPage(items: items, initialText: initialText),
    ),
  );
}

class _MediaCaptionPage extends StatefulWidget {
  final List<OutgoingMedia> items;

  /// Prefill for the caption field — e.g. text already typed in the main
  /// composer when the user attached media (#6). Empty/null = start blank.
  final String? initialText;

  const _MediaCaptionPage({required this.items, this.initialText});

  @override
  State<_MediaCaptionPage> createState() => _MediaCaptionPageState();
}

class _MediaCaptionPageState extends State<_MediaCaptionPage> {
  late final _controller =
      TextEditingController(text: widget.initialText ?? '');
  final _focusNode = FocusNode();

  /// Mutable working copy — editing replaces entries here; the originals stay
  /// untouched until the user actually sends.
  late final List<OutgoingMedia> _items = List.of(widget.items);

  /// Per-index video-trim memory: the ORIGINAL item + the last cut, so a re-edit
  /// reopens the trimmer on the original with the previous handles (never a
  /// prior trim) — used after the "too large" prompt is cancelled.
  final Map<int, _OrigTrim> _trim = {};

  int _selected = 0;

  bool get _isAlbum => _items.length > 1;

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// Send-tap: validate size HERE so a "too large" cancel keeps the user on this
  /// edit sheet (with their trim settings) instead of aborting the whole send.
  Future<void> _send() async {
    final messenger = ScaffoldMessenger.of(context);
    // Hard per-file cap (painting an image can grow it; check uniformly).
    if (_items.any((i) => i.size > MediaRepository.maxUploadBytes)) {
      messenger.showSnackBar(SnackBar(
        content:
            Text('media.too_large'.tr(args: [MediaRepository.maxUploadLabel])),
      ));
      return; // stay — the user can trim further
    }
    // Soft large-send warning on the (possibly trimmed) total, right before
    // sending. Cancel → stay on this sheet with the edit settings preserved.
    final total = _items.fold<int>(0, (s, i) => s + i.size);
    if (total > MediaRepository.largeFileWarnBytes) {
      final proceed = await _confirmLargeFile(context, total);
      if (proceed != true) return;
    }
    if (!mounted) return;
    Navigator.of(context)
        .pop((items: _items, caption: _controller.text.trim()));
  }

  /// "+" tile / action: reopen the gallery and append the picked items (images
  /// by default), up to [maxAlbumItems]. Structural change → drop the index-
  /// keyed trim memory (re-edit starts fresh rather than mis-target a shifted
  /// index).
  Future<void> _addMore() async {
    final remaining = maxAlbumItems - _items.length;
    if (remaining <= 0) return;
    final picked = await pickMoreMedia(context);
    if (picked.isEmpty || !mounted) return;
    setState(() {
      _items.addAll(picked.take(remaining));
      _trim.clear();
    });
    if (picked.length > remaining && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('media.too_many'.tr(args: ['$maxAlbumItems']))),
      );
    }
  }

  /// Remove item [i] from the batch (offered only while there's more than one —
  /// the sheet always needs at least one item to send). Keeps [_selected] on a
  /// valid item; structural change drops the index-keyed trim memory.
  void _removeAt(int i) {
    if (_items.length <= 1) return;
    setState(() {
      _items.removeAt(i);
      _trim.clear();
      if (_selected >= _items.length) _selected = _items.length - 1;
      if (_selected < 0) _selected = 0;
    });
  }

  /// Drag-reorder within the thumbnail strip. Uses the `onReorderItem` contract
  /// where [newIndex] is already the final index for the removed item (no manual
  /// off-by-one adjustment). Keeps [_selected] on the same item (by identity);
  /// drops the index-keyed trim memory.
  void _onReorder(int oldIndex, int newIndex) {
    setState(() {
      final sel = _items[_selected];
      final moved = _items.removeAt(oldIndex);
      _items.insert(newIndex, moved);
      _selected = _items.indexOf(sel);
      _trim.clear();
    });
  }

  Future<void> _editSelected() async {
    final i = _selected;
    final remembered = _trim[i];
    // Video re-edits from the ORIGINAL with the remembered cut (non-destructive
    // re-trim); an image edits from its current (already-edited) bytes.
    final base = remembered?.original ?? _items[i];
    final result =
        await editMedia(context, base, initialTrim: remembered?.settings);
    if (result == null) return; // user backed out of the editor
    setState(() {
      _items[i] = result.item;
      if (result.trim != null) _trim[i] = _OrigTrim(base, result.trim!);
    });
  }

  @override
  Widget build(BuildContext context) {
    final current = _items[_selected];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        // Back = cancel (pops with null → caller aborts the send).
        leading: const BackButton(),
        title: _isAlbum
            ? Text('media.album_count'.tr(args: ['${_items.length}']),
                style: const TextStyle(fontSize: 16))
            : null,
        actions: [
          if (canEdit(current))
            IconButton(
              tooltip: 'media.edit'.tr(),
              icon: const Icon(Icons.edit),
              onPressed: _editSelected,
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: Center(child: _preview(current))),
          // Always show the strip so a single photo can still grow into an
          // album via "+"; the trash affordance appears once there's >1 item.
          if (_items.isNotEmpty) _thumbnailStrip(),
          _captionBar(context),
        ],
      ),
    );
  }

  Widget _preview(OutgoingMedia item) {
    final type = MediaType.fromMime(item.mime);
    switch (type) {
      case MediaType.image:
        return InteractiveViewer(
          // Key by identity so switching items / re-editing rebuilds the image.
          key: ValueKey(item.size ^ _selected),
          boundaryMargin: const EdgeInsets.all(double.infinity),
          minScale: 0.8,
          maxScale: 5,
          child: Image.memory(item.bytes!, fit: BoxFit.contain),
        );
      case MediaType.video:
        // Playable preview (tap/scrub) — works for a bytes source and a large
        // file-path source alike. Keyed so switching album items rebuilds it.
        return _CaptionVideoPreview(key: ValueKey(item.size ^ _selected), item: item);
      case MediaType.audio:
        return _iconPreview(item, Icons.audiotrack, Colors.orangeAccent);
      case MediaType.file:
        final visual = FileTypeVisual.forFile(item.fileName, item.mime);
        return _iconPreview(item, visual.icon, visual.color, label: visual.label);
    }
  }

  Widget _iconPreview(OutgoingMedia item, IconData icon, Color color,
      {String? label}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 96, color: color),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            item.fileName,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 16),
          ),
        ),
        if (label != null) ...[
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(color: Colors.white54)),
        ],
      ],
    );
  }

  Widget _thumbnailStrip() {
    return Container(
      height: 84,
      color: Colors.black,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      // Long-press a thumbnail to drag-reorder; tap to select; the "+" tile at
      // the end (a non-reorderable footer) adds more from the gallery.
      child: ReorderableListView.builder(
        scrollDirection: Axis.horizontal,
        buildDefaultDragHandles: false,
        itemCount: _items.length,
        onReorderItem: _onReorder,
        footer: _addTile(),
        proxyDecorator: (child, index, animation) => Material(
          color: Colors.transparent,
          child: child,
        ),
        itemBuilder: (context, i) => ReorderableDelayedDragStartListener(
          key: ValueKey(_items[i]),
          index: i,
          child: _thumbTile(i),
        ),
      ),
    );
  }

  /// One thumbnail: tap to select; when it's the selected item of a multi-item
  /// batch, a trash badge appears (Gerry: "activate, then the second tap on the
  /// trash removes it").
  Widget _thumbTile(int i) {
    final item = _items[i];
    final selected = i == _selected;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      // Center keeps the tile a fixed 56×56 square; the reorderable slot forces
      // the child to the strip's full height otherwise (stretched thumbnails).
      child: Center(
        child: GestureDetector(
        onTap: () => setState(() => _selected = i),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: selected ? Colors.white : Colors.white24,
                  width: selected ? 2 : 1,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: _thumbnail(item),
            ),
            // Kept INSIDE the tile bounds — a child positioned outside the
            // Stack's box (negative offsets) renders but never receives taps.
            if (selected && _items.length > 1)
              Positioned(
                top: 2,
                right: 2,
                child: GestureDetector(
                  onTap: () => _removeAt(i),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.7),
                      shape: BoxShape.circle,
                    ),
                    padding: const EdgeInsets.all(4),
                    child: const Icon(Icons.delete,
                        size: 16, color: Colors.white),
                  ),
                ),
              ),
          ],
        ),
      ),
      ),
    );
  }

  /// The trailing "+" tile → [_addMore]. Hidden once the batch is full.
  Widget _addTile() {
    if (_items.length >= maxAlbumItems) {
      return const SizedBox.shrink(key: ValueKey('add-tile'));
    }
    return Padding(
      key: const ValueKey('add-tile'),
      padding: const EdgeInsets.only(right: 8),
      // The footer is stretched to the strip's full height; Center keeps the
      // tile a fixed 56×56 square instead of a tall rectangle.
      child: Center(
        child: GestureDetector(
          onTap: _addMore,
          child: Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.white24),
            ),
            child: const Icon(Icons.add_photo_alternate_outlined,
                color: Colors.white70),
          ),
        ),
      ),
    );
  }

  Widget _thumbnail(OutgoingMedia item) {
    if (MediaType.fromMime(item.mime) == MediaType.image) {
      return Image.memory(item.bytes!, fit: BoxFit.cover, cacheWidth: 120);
    }
    final visual = FileTypeVisual.forFile(item.fileName, item.mime);
    return ColoredBox(
      color: Colors.white10,
      child: Icon(
        MediaType.fromMime(item.mime) == MediaType.video
            ? Icons.play_circle_outline
            : visual.icon,
        color: Colors.white70,
      ),
    );
  }

  Widget _captionBar(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        color: Colors.black,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                autofocus: false,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.newline,
                style: const TextStyle(color: Colors.white),
                cursorColor: Colors.white,
                decoration: InputDecoration(
                  hintText: 'media.caption_hint'.tr(),
                  hintStyle: const TextStyle(color: Colors.white54),
                  filled: true,
                  fillColor: Colors.white12,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            FloatingActionButton(
              onPressed: _send,
              mini: true,
              tooltip: 'media.paste_send'.tr(),
              child: const Icon(Icons.send),
            ),
          ],
        ),
      ),
    );
  }
}

/// The ORIGINAL item + the last trim used for it, remembered so a re-edit
/// reopens the trimmer on the original with those handles.
class _OrigTrim {
  final OutgoingMedia original;
  final TrimSettings settings;
  const _OrigTrim(this.original, this.settings);
}

/// "This file is large — send anyway?" confirm, shown at send time on the
/// (possibly trimmed) size. Cancel returns to the edit sheet.
Future<bool?> _confirmLargeFile(BuildContext context, int sizeBytes) {
  if (!context.mounted) return Future.value(false);
  final sizeMb = (sizeBytes / (1024 * 1024)).round();
  return showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('media.large_file_title'.tr()),
      content: Text('media.large_file_warning'.tr(args: ['$sizeMb MB'])),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text('common.cancel'.tr()),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text('media.large_file_send_anyway'.tr()),
        ),
      ],
    ),
  );
}

/// Inline video preview inside the caption sheet: plays the selected video so
/// the user can watch/scrub it before sending. A file-PATH source (large
/// chunked video) opens straight from disk; a bytes source is materialized to a
/// temp file via [VideoSource]. media_kit's default (adaptive) controls give
/// tap-to-toggle + scrub on mobile.
class _CaptionVideoPreview extends StatefulWidget {
  final OutgoingMedia item;
  const _CaptionVideoPreview({super.key, required this.item});

  @override
  State<_CaptionVideoPreview> createState() => _CaptionVideoPreviewState();
}

class _CaptionVideoPreviewState extends State<_CaptionVideoPreview> {
  Player? _player;
  VideoController? _controller;
  VideoSource? _source;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final item = widget.item;
      final String uri;
      if (item.sourcePath != null) {
        uri = item.sourcePath!;
      } else {
        final src =
            await VideoSource.create(item.bytes!, item.fileName, item.mime);
        _source = src;
        uri = src.uri;
      }
      final player = Player();
      final controller = VideoController(
        player,
        configuration: VideoControllerConfiguration(
          enableHardwareAcceleration: !useSoftwareVideoRendering,
        ),
      );
      await player.open(Media(uri), play: false);
      if (!mounted) {
        await player.dispose();
        await _source?.dispose();
        return;
      }
      setState(() {
        _player = player;
        _controller = controller;
      });
    } catch (e) {
      logger.warning('Caption video preview failed: $e', tag: 'CaptionPreview');
      if (mounted) setState(() => _error = true);
    }
  }

  @override
  void dispose() {
    _player?.dispose();
    _source?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error) {
      return const Center(
        child: Icon(Icons.videocam_off, size: 72, color: Colors.white54),
      );
    }
    if (_controller == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return SizedBox.expand(
      child: Video(controller: _controller!, fit: BoxFit.contain),
    );
  }
}
