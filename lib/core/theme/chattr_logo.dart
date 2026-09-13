// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// The speech bubble from the app icon — **without** the rounded tile.
///
/// **Why the shadow comes from Flutter and not from the file.** The original
/// carries the shadow as an SVG filter (`feGaussianBlur` + `feColorMatrix`).
/// Two reasons it is nevertheless missing here: `flutter_svg` does not draw
/// these filters at all, and the exporter's filter region was about 745× too
/// large without `filterUnits` — exactly the fault over which iOS Safari once
/// discarded the bubble entirely ([[svg-filterunits-webkit-trap]]). The landing
/// page has solved it with a CSS shadow ever since; here it is the same thought
/// by Flutter means.
///
/// **And why a shadow at all.** The bubble is almost white (gradient white →
/// `#3A6D8E` at 39 % opacity). On the light themes — "beach", "sakura",
/// "paper", or simply `system` with a light operating system — it would
/// otherwise disappear into the background but for the two eyes. The soft ring
/// gives it an edge without putting a surface underneath it.
class ChattrLogo extends StatelessWidget {
  const ChattrLogo({super.key, this.size = 96});

  final double size;

  @override
  Widget build(BuildContext context) {
    final logo = SvgPicture.asset(
      'assets/images/logo.svg',
      width: size,
      height: size,
      // Purely decorative: the app's name stands directly beneath it, and
      // reading "Chattr" out a second time helps nobody.
      excludeFromSemantics: true,
    );

    // On a dark ground the light bubble needs no edge — there the ring would be
    // mere dirt.
    final hell = Theme.of(context).brightness == Brightness.light;
    if (!hell) return logo;

    return Stack(
      alignment: Alignment.center,
      children: [
        ImageFiltered(
          imageFilter: ui.ImageFilter.blur(sigmaX: 6, sigmaY: 6),
          child: ColorFiltered(
            colorFilter: const ColorFilter.mode(
              Color(0x593A6D8E),
              BlendMode.srcATop,
            ),
            child: logo,
          ),
        ),
        logo,
      ],
    );
  }
}
