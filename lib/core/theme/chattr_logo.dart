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
/// **The ring's shadow.** In the app icon the "C" ring casts a soft blue
/// shadow onto the bubble (`feOffset dy=20`, `feGaussianBlur 25`, `#3A6D8E`, in
/// the 1024 grid) — that is what lifts the ring off the bubble. Without it the
/// two whites merge into one flat shape (Gerry, 2026-10-04, on the Galaxy).
/// So the ring comes once more on its own (`logo_ring.svg`): tinted and blurred
/// as the shadow, then drawn again on top. The shadow falls on the eyes too,
/// exactly as in the icon. Unlike the edge below it belongs to the design, not
/// to the theme, so it is there on every ground.
///
/// **And why an edge at all.** The bubble is almost white (gradient white →
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
    SvgPicture ring() => SvgPicture.asset(
          'assets/images/logo_ring.svg',
          width: size,
          height: size,
          excludeFromSemantics: true,
        );
    // The icon's numbers are in a 1024 grid; scale them to the drawn size.
    final unit = size / 1024;
    final ringShadow = Transform.translate(
      offset: Offset(0, 20 * unit),
      child: ImageFiltered(
        imageFilter: ui.ImageFilter.blur(sigmaX: 25 * unit, sigmaY: 25 * unit),
        child: ColorFiltered(
          colorFilter: const ColorFilter.mode(
            Color(0xFF3A6D8E),
            BlendMode.srcIn,
          ),
          child: ring(),
        ),
      ),
    );

    // On a dark ground the light bubble needs no edge — there the ring would be
    // mere dirt.
    final hell = Theme.of(context).brightness == Brightness.light;

    return Stack(
      alignment: Alignment.center,
      children: [
        if (hell)
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
        ringShadow,
        ring(),
      ],
    );
  }
}
