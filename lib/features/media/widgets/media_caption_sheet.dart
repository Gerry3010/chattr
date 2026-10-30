// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../core/logging/logger_service.dart';
import '../../../core/navigation/app_page_route.dart';
import '../../settings/media_quality_controller.dart';
import '../editing/media_edit_launcher.dart';
import '../editing/video_trim_screen.dart' show TrimSettings;
import '../media_attachment.dart';
import '../media_repository.dart';
import '../shot_caption_burn.dart';
import '../shot_text_blocks.dart';
import '../video_render_config.dart';
import '../video_source.dart';
import 'attach_menu.dart' show maxAlbumItems, pickMoreMedia;
import 'caption_slot.dart';
import 'file_type_visuals.dart';

/// Result of the caption sheet: the (possibly edited) items, the shared
/// caption, and — only if the user touched the switch — the quality choice FOR
/// THIS SEND. `quality: null` explicitly means "as configured": the send path
/// then resolves the stored default itself and waits for it to load, rather
/// than freezing a possibly not-yet-loaded value here. `null` return from
/// [showMediaCaptionSheet] means the user backed out.
typedef CaptionSheetResult = ({
  List<OutgoingMedia> items,
  String caption,
  MediaQuality? quality,
  bool asShot,
});

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
  bool initialAsShot = false,
}) {
  return Navigator.of(context).push<CaptionSheetResult>(
    appPageRoute<CaptionSheetResult>(
      fullscreenDialog: true,
      builder: (_) => _MediaCaptionPage(
        items: items,
        initialText: initialText,
        initialAsShot: initialAsShot,
      ),
    ),
  );
}

class _MediaCaptionPage extends ConsumerStatefulWidget {
  final List<OutgoingMedia> items;

  /// Prefill for the caption field — e.g. text already typed in the main
  /// composer when the user attached media (#6). Empty/null = start blank.
  final String? initialText;

  /// Preset of the shot switch. It arrives on from the camera (the tile is
  /// called "Shot"), not from the gallery — there a lasting message is what one
  /// expects.
  final bool initialAsShot;

  const _MediaCaptionPage({
    required this.items,
    this.initialText,
    this.initialAsShot = false,
  });

  @override
  ConsumerState<_MediaCaptionPage> createState() => _MediaCaptionPageState();
}

class _MediaCaptionPageState extends ConsumerState<_MediaCaptionPage> {
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

  /// The quality choice for this send ONLY — `null` for as long as the user has
  /// not touched the switch. Then the stored default decides, and only in the
  /// send path (see [CaptionSheetResult]).
  MediaQuality? _quality;

  /// „Einmal ansehen" fuer diesen Versand.
  late bool _asShot = widget.initialAsShot;

  /// The text blocks that are rendered INTO the photo when sending (not placed
  /// beside it — see [burnShotTextBlocks]). Only for a photo shot, and only
  /// here: they never leave this sheet as text.
  final List<ShotTextBlock> _shotBlocks = [];

  /// Welcher Abschnitt gerade bearbeitet wird — `null` heisst: keiner.
  int? _shotBearbeitet;

  final _shotTextController = TextEditingController();
  final _shotTextFocus = FocusNode();

  /// The dimensions of the photo in PIXELS — needed so the bar in the preview
  /// is exactly as wide as the picture and not as wide as the screen.
  Size? _photoDims;
  int? _photoMeasuredFor;

  /// Photo shot — only there is there a line. Captioning a video would mean re-
  /// encoding it.
  bool get _canHaveShotText =>
      _asShot &&
      _canBeShot &&
      MediaType.fromMime(_items.first.mime) == MediaType.image;

  bool get _isAlbum => _items.length > 1;

  /// What the switch currently shows: one's own choice, otherwise the default.
  MediaQuality get _effectiveQuality =>
      _quality ?? ref.watch(mediaQualityProvider);

  /// The switch only appears when it can do something. On a pure audio or
  /// document send there is nothing to shrink, and a button that does nothing
  /// is worse than no button.
  bool get _canDownscale => _items.any((i) {
        final t = MediaType.fromMime(i.mime);
        return t == MediaType.image || t == MediaType.video;
      });

  /// A shot is EXACTLY ONE photo or video. A stack in which every picture
  /// expires separately would no longer be a message but an administration task
  /// — and an album that expires as a whole would be surprising.
  bool get _canBeShot {
    if (_items.length != 1) return false;
    final t = MediaType.fromMime(_items.first.mime);
    return t == MediaType.image || t == MediaType.video;
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    _shotTextController.dispose();
    _shotTextFocus.dispose();
    super.dispose();
  }

  /// Send-tap: validate size HERE so a "too large" cancel keeps the user on this
  /// edit sheet (with their trim settings) instead of aborting the whole send.
  Future<void> _send() async {
    final messenger = ScaffoldMessenger.of(context);
    _closeShotText();

    // The text is rendered into the photo HERE, not in the send path — that
    // stays untouched and gets an ordinary picture.
    //
    // The result lands in a LOCAL list, not in `_items`: if the user cancels
    // right below at "large file", they are back here — and a second attempt
    // would otherwise paint the sentence into the already-captioned picture a
    // second time.
    var items = _items;
    if (_canHaveShotText && _shotBlocks.isNotEmpty) {
      items = [
        await burnShotTextBlocks(_items.first, _shotBlocks),
        ..._items.skip(1),
      ];
      if (!mounted) return;
    }

    // Hard per-file cap (painting an image can grow it; check uniformly).
    if (items.any((i) => i.size > MediaRepository.maxUploadBytes)) {
      messenger.showSnackBar(SnackBar(
        content:
            Text('media.too_large'.tr(args: [MediaRepository.maxUploadLabel])),
      ));
      return; // stay — the user can trim further
    }
    // Soft large-send warning on the (possibly trimmed) total, right before
    // sending. Cancel → stay on this sheet with the edit settings preserved.
    final total = items.fold<int>(0, (s, i) => s + i.size);
    if (total > MediaRepository.largeFileWarnBytes) {
      final proceed = await _confirmLargeFile(
        context,
        total,
        // The number is the size BEFORE downscaling — there is no other way
        // without pushing the video through the encoder first. So the text says
        // as much, instead of naming a number that will not hold afterwards.
        // And it warns about what really takes time here: not the upload but
        // the downscaling itself.
        willDownscale: _effectiveQuality == MediaQuality.smaller &&
            _canDownscale,
      );
      if (proceed != true) return;
    }
    if (!mounted) return;
    Navigator.of(context).pop((
      items: items,
      caption: _controller.text.trim(),
      quality: _quality,
      // A shot stays one only as long as it can be one — if the stack grows
      // after the switch, the marking falls away.
      asShot: _asShot && _canBeShot,
    ));
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
          if (_canBeShot) _shotAction(),
          if (_canDownscale) _qualityAction(),
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
          // A shot carries no caption: it would stay in the bubble after the
          // picture is gone — a remnant of the message that was supposed to
          // disappear. The field is therefore replaced and not silently
          // ignored.
          _captionBar(context, shot: _asShot && _canBeShot),
        ],
      ),
    );
  }

  /// The "send at full quality / send smaller" toggle — applies to this send
  /// only and does not change the setting.
  ///
  /// Deliberately a state button and not a menu: there are exactly two steps,
  /// and a menu for two entries costs one more tap without explaining anything.
  /// The state shows in the icon AND in the tint, so it does not hang on colour
  /// alone.
  Widget _qualityAction() {
    final smaller = _effectiveQuality == MediaQuality.smaller;
    return IconButton(
      tooltip: smaller
          ? 'media_quality.sending_smaller'.tr()
          : 'media_quality.sending_original'.tr(),
      icon: Icon(
        // ONE icon, two states — as with the shot switch beside it: filled and
        // coloured means "HQ is on", outlined and plain means "not at full
        // resolution". No change of shape when toggling, and the emphasis sits
        // on the state with the larger consequence (full resolution = large
        // upload).
        smaller ? Icons.high_quality_outlined : Icons.high_quality,
        color: smaller ? null : Theme.of(context).colorScheme.primary,
      ),
      onPressed: () => setState(() {
        _quality =
            smaller ? MediaQuality.original : MediaQuality.smaller;
      }),
    );
  }

  /// Der Umschalter „einmal ansehen".
  Widget _shotAction() {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: _asShot
          ? 'shots.sending_as_shot'.tr()
          : 'shots.send_as_shot'.tr(),
      icon: Icon(
        _asShot ? Icons.timer : Icons.timer_outlined,
        color: _asShot ? scheme.primary : null,
      ),
      onPressed: () {
        // Away from the shot means away from the line: it belongs here only,
        // and an open field above an ordinary photo would be a promise the send
        // path does not keep.
        if (_asShot) _closeShotText();
        setState(() => _asShot = !_asShot);
      },
    );
  }

  Widget _preview(OutgoingMedia item) {
    final type = MediaType.fromMime(item.mime);
    switch (type) {
      case MediaType.image:
        final image = InteractiveViewer(
          // Key by identity so switching items / re-editing rebuilds the image.
          key: ValueKey(item.size ^ _selected),
          boundaryMargin: const EdgeInsets.all(double.infinity),
          minScale: 0.8,
          maxScale: 5,
          child: Image.memory(item.bytes!, fit: BoxFit.contain),
        );
        if (!_canHaveShotText) return image;
        _measurePhoto(item);
        // The bars belong ON THE PICTURE, not on the screen. Without that they
        // run far beyond the photo in the preview — and then get burned inside
        // it anyway, with a different line break. A preview that looks
        // different from the result is worse than no preview (Gerry on the
        // device, 2026-08-28).
        return LayoutBuilder(
          builder: (context, c) {
            final rect = _photoRect(Size(c.maxWidth, c.maxHeight));
            return Stack(
              fit: StackFit.expand,
              children: [
                image,
                if (rect != null)
                  Center(
                    child: SizedBox(
                      width: rect.width,
                      height: rect.height,
                      child: _shotTextOverlay(rect),
                    ),
                  ),
              ],
            );
          },
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

  /// Measures the photo ONCE (only the header of the file, no full decode) and
  /// remembers the dimensions. Without them the preview does not know how wide
  /// the picture sits on screen.
  void _measurePhoto(OutgoingMedia item) {
    final key = identityHashCode(item);
    if (_photoMeasuredFor == key) return;
    _photoMeasuredFor = key;
    _photoDims = null;
    final bytes = item.bytes;
    if (bytes == null) return;
    () async {
      try {
        final puffer = await ui.ImmutableBuffer.fromUint8List(bytes);
        final description = await ui.ImageDescriptor.encoded(puffer);
        final masse = Size(description.width.toDouble(),
            description.height.toDouble());
        description.dispose();
        puffer.dispose();
        if (!mounted || _photoMeasuredFor != key) return;
        setState(() => _photoDims = masse);
      } catch (_) {
        // Unmeasurable: then there is simply no bar. The rest works.
      }
    }();
  }

  /// Where the photo actually sits inside a box of [platz] — the same
  /// arithmetic `BoxFit.contain` does.
  Size? _photoRect(Size space) {
    final masse = _photoDims;
    if (masse == null || masse.width <= 0 || masse.height <= 0) return null;
    if (!space.width.isFinite || !space.height.isFinite) return null;
    final faktor = math.min(
        space.width / masse.width, space.height / masse.height);
    return Size(masse.width * faktor, masse.height * faktor);
  }

  /// The layer with all text blocks above the photo.
  ///
  /// **A tap on the picture creates a new block exactly where the finger was**
  /// — and not in the middle, where the single bar sat until 1.28. The catcher
  /// for that lies BENEATH the blocks: whoever taps an existing one wants to
  /// edit it, not to place a second one on top.
  Widget _shotTextOverlay(Size image) {
    // **The same arithmetic as when burning** — [ShotCaptionStyle.fontSizeFor]
    // is the one source, applied to the rectangle the photo currently occupies
    // on screen. Bounded from below only, so the type stays readable with the
    // keyboard up (a tiny preview): there the preview deliberately deviates
    // from the result, because an illegible field while typing would be the
    // worse trade.
    final fontSize =
        math.max(11.0, ShotCaptionStyle.fontSizeFor(image.width, image.height));
    final padding = fontSize * ShotCaptionStyle.paddingRatio;

    return Stack(
      children: [
        // `translucent` and not `opaque`: the tap is ours, the drag still
        // belongs to the picture. An opaque catcher would have swallowed the
        // pinch to zoom as well.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTapUp: (d) => _shotTextNeu(d.localPosition.dy / image.height),
          ),
        ),
        if (_shotBlocks.isEmpty && _shotBearbeitet == null)
          // Nothing typed: a restrained hint, so that anyone gets the idea to
          // tap at all. It does NOT travel into the picture and catches no taps
          // either — the catcher beneath does that.
          Center(
            child: IgnorePointer(
              child: Container(
                color: ShotCaptionStyle.background,
                padding: EdgeInsets.symmetric(
                    horizontal: padding, vertical: padding * 0.7),
                child: Text(
                  'shots.text_add'.tr(),
                  style: TextStyle(
                      color: Colors.white70, fontSize: fontSize * 0.8),
                ),
              ),
            ),
          ),
        for (var i = 0; i < _shotBlocks.length; i++)
          _shotTextLayer(i, image, fontSize, padding),
      ],
    );
  }

  /// A single bar: the sentence at rest, an input field in the same place while
  /// typing.
  ///
  /// Colours and position come from [ShotCaptionStyle] and [shotTextBlockTop] —
  /// the same sources that are painted into the picture when sending. The
  /// preview cannot hit it exactly (it measures in logical pixels, the picture
  /// in image pixels), but it must not LOOK different.
  Widget _shotTextLayer(int index, Size image, double fontSize, double padding) {
    final bearbeitet = _shotBearbeitet == index;
    final text =
        bearbeitet ? _shotTextController.text : _shotBlocks[index].text;
    final height = _bandHeight(
      text.isEmpty ? ' ' : text,
      fontSize: fontSize,
      padding: padding,
      width: image.width,
    );
    final top = shotTextBlockTop(
      y: _shotBlocks[index].y,
      bandHeight: height,
      imageHeight: image.height,
    );

    return Positioned(
      left: 0,
      right: 0,
      top: top,
      child: GestureDetector(
        // Opaque here: a tap on an existing block should open it and NOT create
        // a new one down at the catcher.
        behavior: HitTestBehavior.opaque,
        onTap: bearbeitet ? null : () => _shotTextBearbeite(index),
        onVerticalDragUpdate: (d) => _shotTextVerschiebe(index, d.delta.dy, image),
        child: bearbeitet
            ? _shotTextField(fontSize, padding)
            : Container(
                width: double.infinity,
                color: ShotCaptionStyle.background,
                padding:
                    EdgeInsets.symmetric(horizontal: padding, vertical: padding),
                child: Text(
                  text,
                  textAlign: TextAlign.center,
                  maxLines: ShotCaptionStyle.maxLines,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: ShotCaptionStyle.foreground,
                    fontSize: fontSize,
                    height: 1.25,
                  ),
                ),
              ),
      ),
    );
  }

  Widget _shotTextField(double fontSize, double padding) => Container(
        width: double.infinity,
        color: ShotCaptionStyle.background,
        padding: EdgeInsets.symmetric(horizontal: padding, vertical: padding),
        child: TextField(
          controller: _shotTextController,
          focusNode: _shotTextFocus,
          autofocus: true,
          maxLines: ShotCaptionStyle.maxLines,
          minLines: 1,
          maxLength: ShotCaptionStyle.maxChars,
          textAlign: TextAlign.center,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _closeShotText(),
          onTapOutside: (_) => _closeShotText(),
          style: TextStyle(
            color: ShotCaptionStyle.foreground,
            fontSize: fontSize,
            height: 1.25,
          ),
          cursorColor: ShotCaptionStyle.foreground,
          decoration: InputDecoration(
            isDense: true,
            border: InputBorder.none,
            // The counter would otherwise sit as a white blob over the photo;
            // the limit still applies.
            counterText: '',
            hintText: 'shots.text_hint'.tr(),
            hintStyle: TextStyle(color: Colors.white54, fontSize: fontSize),
          ),
          onChanged: (_) => setState(() {}),
        ),
      );

  /// How tall the bar becomes for this text — **before** drawing, because the
  /// position depends on the height. The same measurement as when burning, only
  /// at screen scale.
  double _bandHeight(String text,
      {required double fontSize, required double padding, required double width}) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontSize: fontSize, height: 1.25),
      ),
      textAlign: TextAlign.center,
      // `ui.` spelled out: easy_localization brings a `TextDirection` of its
      // own, which would otherwise win here.
      textDirection: ui.TextDirection.ltr,
      maxLines: ShotCaptionStyle.maxLines,
      ellipsis: '…',
    )..layout(maxWidth: math.max(1, width - 2 * padding));
    return painter.height + 2 * padding;
  }

  /// Neuer Abschnitt an der angetippten Hoehe.
  void _shotTextNeu(double yAnteil) {
    _closeShotText();
    if (_shotBlocks.length >= kMaxShotTextBlocks) return;
    setState(() {
      _shotBlocks.add(
          ShotTextBlock(text: '', y: yAnteil.clamp(0.0, 1.0)));
      _shotBearbeitet = _shotBlocks.length - 1;
      _shotTextController.text = '';
    });
  }

  void _shotTextBearbeite(int index) {
    if (_shotBearbeitet == index) return;
    _closeShotText();
    if (index >= _shotBlocks.length) return;
    setState(() {
      _shotBearbeitet = index;
      _shotTextController.text = _shotBlocks[index].text;
    });
  }

  void _shotTextVerschiebe(int index, double dy, Size image) {
    if (image.height <= 0) return;
    setState(() {
      final b = _shotBlocks[index];
      _shotBlocks[index] =
          b.copyWith(y: (b.y + dy / image.height).clamp(0.0, 1.0));
    });
  }

  /// End the input — **and throw away a block left empty.** Nothing written
  /// means nothing meant; hunting for a delete button for it would be work for
  /// something that is not there.
  void _closeShotText() {
    final index = _shotBearbeitet;
    if (index == null) return;
    _shotTextFocus.unfocus();
    final text = _shotTextController.text.trim();
    setState(() {
      _shotBearbeitet = null;
      if (index >= _shotBlocks.length) return;
      if (text.isEmpty) {
        _shotBlocks.removeAt(index);
      } else {
        _shotBlocks[index] = _shotBlocks[index].copyWith(text: text);
      }
    });
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

  /// The bar below the preview. For a shot, a hint stands in place of the input
  /// field — **in the same bar, with the same dimensions**.
  ///
  /// That is not cosmetics: were the two states of different heights, the
  /// preview above would jump when toggling (Gerry saw exactly that on the
  /// device). So only the content of the `Expanded` changes; frame, padding and
  /// the send button stay the same widgets. The hint carries the same fill, the
  /// same radius and the same padding as the text field in its single-line form
  /// — the height is thereby equal, not merely similar.
  Widget _captionBar(BuildContext context, {bool shot = false}) {
    return SafeArea(
      top: false,
      child: Container(
        color: Colors.black,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: CaptionSlot(
                shot: shot,
                controller: _controller,
                focusNode: _focusNode,
                hintText: 'media.caption_hint'.tr(),
                shotHintText: 'shots.compose_hint'.tr(),
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
Future<bool?> _confirmLargeFile(
  BuildContext context,
  int sizeBytes, {
  bool willDownscale = false,
}) {
  if (!context.mounted) return Future.value(false);
  final sizeMb = (sizeBytes / (1024 * 1024)).round();
  return showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('media.large_file_title'.tr()),
      content: Text((willDownscale
              ? 'media.large_file_warning_smaller'
              : 'media.large_file_warning')
          .tr(args: ['$sizeMb MB'])),
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
