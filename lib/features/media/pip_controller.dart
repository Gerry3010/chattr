// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'video_source.dart';

/// The four screen corners a PiP window can snap to.
enum PipCorner { topLeft, topRight, bottomLeft, bottomRight }

/// A video that has been "promoted" out of its inline chat bubble into the
/// floating picture-in-picture window. The [PipController] now OWNS these native
/// objects — it keeps them alive (playing) independent of the ListView bubble's
/// lifecycle, and disposes them when the window is closed. The originating
/// bubble relinquished ownership on promote (so its own dispose won't tear them
/// down) — see `video_message_player.dart`.
class PipVideo {
  final Player player;
  final VideoController controller;

  /// The decrypted temp-file source for a chat video (disposed with the window).
  /// Null for a link video (Reddit/og:video), which streams from a network URL.
  final VideoSource? source;

  /// Where this video lives, so the PiP window can dock it back into its bubble
  /// (chat video or inline link video alike, matched by [messageId]). Null when
  /// a chat video's storage path wasn't in the `<chatId>/<messageId>/…` layout.
  final String? chatId;
  final String? messageId;

  /// Display name (for a11y / tooltip) and intrinsic aspect ratio (w/h) so the
  /// floating window matches the video shape instead of a fixed landscape box.
  final String name;
  final double? aspect;

  const PipVideo({
    required this.player,
    required this.controller,
    required this.name,
    this.source,
    this.chatId,
    this.messageId,
    this.aspect,
  });
}

/// A YouTube link video floating in the PiP window. Unlike [PipVideo] there is
/// no live handoff: the YouTube iframe is an Android platform view that does not
/// survive being reparented, so the floating window (and the docked-back bubble)
/// each build a FRESH controller from [youtubeId] resuming at [start] seconds —
/// a brief reload rather than a seamless move. Only the small data travels here.
class PipYoutube {
  final String youtubeId;

  /// Playback position (seconds) to resume at when the window/bubble rebuilds
  /// its controller.
  final double start;

  /// Vertical (Shorts) → 9:16 window; else 16:9. Also the [aspect] shortcut.
  final bool vertical;

  final String? chatId;
  final String? messageId;
  final String name;

  const PipYoutube({
    required this.youtubeId,
    required this.name,
    this.start = 0,
    this.vertical = false,
    this.chatId,
    this.messageId,
  });

  double get aspect => vertical ? 9 / 16 : 16 / 9;
}

/// Owns the single active picture-in-picture video (if any). Lives above the
/// Navigator (see `PipOverlayHost` in `app.dart`) so the floating window — and
/// the underlying media_kit [Player] — survive scrolling, chat navigation, and
/// route changes. Only one video floats at a time; promoting a second closes the
/// first.
class PipController extends ChangeNotifier {
  PipVideo? _video;
  PipVideo? get video => _video;

  PipYoutube? _youtube;
  PipYoutube? get youtube => _youtube;

  bool get hasVideo => _video != null || _youtube != null;

  /// The floating video's message id (media_kit or YouTube), so its bubble knows
  /// PiP holds it (placeholder) and can re-adopt on dock.
  String? get pipMessageId => _video?.messageId ?? _youtube?.messageId;

  PipCorner _corner = PipCorner.bottomRight;
  PipCorner get corner => _corner;

  /// Set when the user asks to dock the floating video back into its chat
  /// bubble. The matching inline bubble picks this up on build and calls
  /// [takeForDock] / [takeYoutubeForDock] to re-adopt.
  bool _dockRequested = false;
  bool get dockRequested => _dockRequested;

  /// Playback position (seconds) captured when a YouTube video is docked back,
  /// so the bubble's fresh controller resumes there.
  double? _dockYoutubeStart;
  double? get dockYoutubeStart => _dockYoutubeStart;

  /// Counts promotions. The window is keyed on it, so every new video starts
  /// with a fresh window (and with [openMaximized] read anew).
  int _generation = 0;
  int get generation => _generation;

  /// The window opens maximized: the inline YouTube player's fullscreen button
  /// goes through here, since the iframe's own fullscreen is confined to the
  /// bubble now.
  bool _openMaximized = false;
  bool get openMaximized => _openMaximized;

  /// Promote a media_kit [video] into the floating window, taking ownership of
  /// its native objects. Any previously floating video is disposed first.
  void promote(PipVideo video) {
    _disposeCurrent();
    _generation++;
    _openMaximized = false;
    _video = video;
    _corner = PipCorner.bottomRight;
    _dockRequested = false;
    _dockYoutubeStart = null;
    notifyListeners();
  }

  /// Promote a YouTube link video into the floating window (the window builds a
  /// fresh controller from its data — see [PipYoutube]).
  void promoteYoutube(PipYoutube youtube, {bool maximized = false}) {
    _disposeCurrent();
    _generation++;
    _openMaximized = maximized;
    _youtube = youtube;
    _corner = PipCorner.bottomRight;
    _dockRequested = false;
    _dockYoutubeStart = null;
    notifyListeners();
  }

  /// Ask for the floating video to dock back into its chat bubble. Does NOT
  /// dispose — the bubble re-adopts. [youtubeStart] carries the captured YouTube
  /// position so the docked bubble resumes there.
  void requestDock({double? youtubeStart}) {
    if (!hasVideo || _dockRequested) return;
    _dockRequested = true;
    _dockYoutubeStart = youtubeStart;
    notifyListeners();
  }

  /// Handed to the inline bubble ready to re-adopt the docked media_kit video.
  /// Clears the window WITHOUT disposing — ownership returns to the bubble.
  PipVideo? takeForDock() {
    if (!_dockRequested || _video == null) return null;
    final v = _video;
    _video = null;
    _dockRequested = false;
    notifyListeners();
    return v;
  }

  /// Handed to the inline bubble ready to re-adopt the docked YouTube video. The
  /// window's controller is disposed as the window unmounts; the bubble builds a
  /// fresh one at [dockYoutubeStart].
  PipYoutube? takeYoutubeForDock() {
    if (!_dockRequested || _youtube == null) return null;
    final y = _youtube;
    _youtube = null;
    _dockRequested = false;
    notifyListeners();
    return y;
  }

  /// Move the window to [corner] (after a drag snaps to the nearest one).
  void setCorner(PipCorner corner) {
    if (_corner == corner) return;
    _corner = corner;
    notifyListeners();
  }

  /// Close the floating window and dispose its player + source.
  void close() {
    if (!hasVideo) return;
    _disposeCurrent();
    notifyListeners();
  }

  void _disposeCurrent() {
    final v = _video;
    _video = null;
    // YouTube: the window owns its controller and disposes it on unmount; here
    // we just drop the descriptor.
    _youtube = null;
    if (v != null) {
      // Fire-and-forget: media_kit dispose is async but we don't block the UI.
      v.player.dispose();
      v.source?.dispose();
    }
  }

  @override
  void dispose() {
    _disposeCurrent();
    super.dispose();
  }
}

final pipControllerProvider =
    ChangeNotifierProvider<PipController>((ref) => PipController());

/// The corner a window centered at [center] should snap to within a [screen] of
/// the given size — nearest by both axes. Pure (no widgets) so it is unit-tested.
PipCorner nearestCorner(Offset center, Size screen) {
  final left = center.dx < screen.width / 2;
  final top = center.dy < screen.height / 2;
  if (top) return left ? PipCorner.topLeft : PipCorner.topRight;
  return left ? PipCorner.bottomLeft : PipCorner.bottomRight;
}
