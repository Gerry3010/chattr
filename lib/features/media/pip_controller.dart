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

  /// Where this video lives, so the PiP window can jump back to it. Null when the
  /// storage path wasn't in the `<chatId>/<messageId>/…` layout, or for a link
  /// video (which docks back by re-opening its popup, not a chat bubble).
  final String? chatId;
  final String? messageId;

  /// Display name (for a11y / tooltip) and intrinsic aspect ratio (w/h) so the
  /// floating window matches the video shape instead of a fixed landscape box.
  final String name;
  final double? aspect;

  /// A Reddit/og:video link video (media_kit network stream) rather than a chat
  /// attachment: it has no chat bubble to dock into, so the window re-opens its
  /// popup dialog instead (see `PipOverlayHost`). [vertical] shapes that dialog.
  final bool isLinkVideo;
  final bool vertical;

  const PipVideo({
    required this.player,
    required this.controller,
    required this.name,
    this.source,
    this.chatId,
    this.messageId,
    this.aspect,
    this.isLinkVideo = false,
    this.vertical = false,
  });
}

/// Owns the single active picture-in-picture video (if any). Lives above the
/// Navigator (see `PipOverlayHost` in `app.dart`) so the floating window — and
/// the underlying media_kit [Player] — survive scrolling, chat navigation, and
/// route changes. Only one video floats at a time; promoting a second closes the
/// first.
class PipController extends ChangeNotifier {
  PipVideo? _video;
  PipVideo? get video => _video;
  bool get hasVideo => _video != null;

  PipCorner _corner = PipCorner.bottomRight;
  PipCorner get corner => _corner;

  /// Set when the user asks to dock the floating video back into its chat
  /// bubble. The matching inline bubble picks this up on build and calls
  /// [takeForDock] to re-adopt the SAME player (no re-decrypt).
  bool _dockRequested = false;
  bool get dockRequested => _dockRequested;

  /// Promote [video] into the floating window, taking ownership of its native
  /// objects. Any previously floating video is disposed first.
  void promote(PipVideo video) {
    _disposeCurrent();
    _video = video;
    _corner = PipCorner.bottomRight;
    _dockRequested = false;
    notifyListeners();
  }

  /// Ask for the floating video to dock back into its chat bubble. Does NOT
  /// dispose — the bubble re-adopts the live player via [takeForDock].
  void requestDock() {
    if (_video == null || _dockRequested) return;
    _dockRequested = true;
    notifyListeners();
  }

  /// Handed to the inline bubble that's ready to re-adopt the docked video
  /// (dock requested + its messageId matches). Clears the window WITHOUT
  /// disposing — ownership returns to the bubble. Null if no dock is pending.
  PipVideo? takeForDock() {
    if (!_dockRequested || _video == null) return null;
    final v = _video;
    _video = null;
    _dockRequested = false;
    notifyListeners();
    return v;
  }

  /// Remove the floating video WITHOUT disposing and return it — the caller now
  /// owns the native objects. Used when a link video docks back into a freshly
  /// re-opened popup dialog. Null if nothing floats.
  PipVideo? detach() {
    if (_video == null) return null;
    final v = _video;
    _video = null;
    _dockRequested = false;
    notifyListeners();
    return v;
  }

  /// Move the window to [corner] (after a drag snaps to the nearest one).
  void setCorner(PipCorner corner) {
    if (_corner == corner) return;
    _corner = corner;
    notifyListeners();
  }

  /// Close the floating window and dispose its player + source.
  void close() {
    if (_video == null) return;
    _disposeCurrent();
    notifyListeners();
  }

  void _disposeCurrent() {
    final v = _video;
    _video = null;
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
