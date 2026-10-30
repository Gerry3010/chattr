// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:ui' show ImageFilter;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../media_attachment.dart';
import '../shot_envelope.dart';

/// The colour of a shot — **one for image, a different one for video**.
///
/// Deliberately fixed tones and not ones derived from the colour scheme: a shot
/// should stand out from the conversation, and a tone that shifts along with
/// the design does that sometimes more and sometimes less. Both are chosen to
/// carry on a light ground as well as a dark one.
///
/// But the colour is NEVER the only difference: photo and video also have
/// different icons. Whoever distinguishes colours poorly reads the type off the
/// icon — and the state off filled/hollow, not off a shade.
class ShotVisual {
  const ShotVisual(this.color, this.icon);

  final Color color;
  final IconData icon;

  static const ShotVisual image =
      ShotVisual(Color(0xFFE0245E), Icons.photo_camera);
  static const ShotVisual video =
      ShotVisual(Color(0xFF7C4DFF), Icons.videocam);

  static ShotVisual forKind(MediaType kind) =>
      kind == MediaType.video ? video : image;
}

/// A shot's bubble: a badge, the word "Shot" and a line about the state.
///
/// **Filled means "still there", hollow means "already seen".** That is the
/// convention everybody knows from Snapchat, and it manages without text — the
/// text underneath only says more precisely what filled/hollow already shows.
class ShotMessageBubble extends StatelessWidget {
  const ShotMessageBubble({
    super.key,
    required this.shot,
    required this.isOwn,
    required this.openedByPeer,
    this.onOpen,
  });

  final ShotEnvelope shot;
  final bool isOwn;

  /// Only relevant on the sender's side: has the recipient opened it? Falls out
  /// of the read receipt — whoever has switched those off sends none here
  /// either, and then it stays at "not opened yet".
  final bool openedByPeer;

  /// Only set when the shot can actually be opened.
  final VoidCallback? onOpen;

  /// The sender may go in **too** (Gerry, 2026-08-28) — they should be able to
  /// check what they sent, for as long as the bubble stands. Nothing is
  /// consumed in doing so: their copy only falls with the 24-hour clock, and
  /// that runs off the other side's read mark, not off their look.
  bool get _oeffenbar => onOpen != null && !_gone;

  bool get _gone => shot.isConsumed;

  bool get _filled => !_gone && !(isOwn && openedByPeer);

  String get _statusKey {
    if (_gone) return 'shots.gone';
    if (isOwn) {
      return openedByPeer ? 'shots.opened' : 'shots.unopened_outgoing';
    }
    return 'shots.unopened_incoming';
  }

  @override
  Widget build(BuildContext context) {
    final visual = ShotVisual.forKind(shot.kind);
    final scheme = Theme.of(context).colorScheme;
    final tappable = _oeffenbar;

    // Frosted glass rather than a veil: the chat background is patterned, and a
    // merely semi-transparent surface over it turns to mush — the pattern shows
    // through the type. The blur behind it hints at the background without it
    // reading along. Same means and same strength as the formatting bar in the
    // composer.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: Material(
            // Material instead of Container: that way the tap ripple lies ON
            // the blurred surface instead of underneath it, where nobody would
            // see it.
            color: _filled
                ? visual.color.withValues(alpha: 0.16)
                : scheme.surfaceContainerHighest.withValues(alpha: 0.55),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
              side: BorderSide(
                color: _filled
                    ? visual.color.withValues(alpha: 0.55)
                    // Consumed means withdrawn: `outlineVariant` is almost
                    // white in dark themes and glowed brighter than the still-
                    // open shots beside it — exactly the wrong way round.
                    : scheme.onSurfaceVariant.withValues(alpha: 0.35),
              ),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(18),
              // Tap ripple, press and focus highlight in the colour of the
              // shot. Without it Material takes the theme's accent colour — in
              // the Matrix theme that is green, flashing over a magenta bubble
              // and looking like an error. The focus stays after tapping, which
              // is why THAT one is the most noticeable (Gerry, 2026-08-28).
              splashColor: visual.color.withValues(alpha: 0.22),
              highlightColor: visual.color.withValues(alpha: 0.12),
              focusColor: visual.color.withValues(alpha: 0.12),
              hoverColor: visual.color.withValues(alpha: 0.08),
              onTap: tappable ? onOpen : null,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _badge(visual, scheme),
                    const SizedBox(width: 10),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'shots.badge'.tr(),
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.4,
                            color:
                                _gone ? scheme.onSurfaceVariant : visual.color,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _statusKey.tr(),
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    // At the recipient the line underneath already says "tap to
                    // view"; at the sender it says something else (whether the
                    // other has looked yet), and without this eye there would
                    // be no way to tell that one's own bubble can be opened at
                    // all.
                    if (isOwn && _oeffenbar) ...[
                      const SizedBox(width: 10),
                      Icon(
                        Icons.visibility_outlined,
                        size: 18,
                        color: scheme.onSurfaceVariant,
                        semanticLabel: 'shots.review_own'.tr(),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Filled = unopened, hollow = consumed. The ring stays visible in both cases
  /// so the bubble keeps its shape.
  Widget _badge(ShotVisual visual, ColorScheme scheme) {
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: _filled ? visual.color : Colors.transparent,
        shape: BoxShape.circle,
        border: Border.all(
          color: _filled ? visual.color : scheme.outlineVariant,
          width: 2,
        ),
      ),
      child: Icon(
        visual.icon,
        size: 20,
        // On the filled surface the icon is white; hollow it carries the type
        // colour, so photo and video stay distinguishable then too.
        color: _filled
            ? Colors.white
            : (_gone ? scheme.onSurfaceVariant : visual.color),
      ),
    );
  }
}
