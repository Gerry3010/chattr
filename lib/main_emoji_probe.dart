// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

/// **Measurement entry point for inline emoji — not part of the app.**
///
/// Gerry, 2026-10-22, on the iPhone: in „🙂“ there is a visible gap after the
/// emoji, in the composer and in the bubble alike, the emoji looks too small,
/// and lines with an emoji grow taller. The text holds nothing hidden
/// (`201E 1F642 201C`), and the caption, which has no emoji handling at all,
/// shows the same gap. So it comes from how the engine lays out and draws
/// Apple Color Emoji, and that cannot be derived, only measured.
///
/// For each text style the app uses and several emoji sizes this lays out
/// „🙂“, paints it into an image and finds the ink: where the emoji is
/// actually drawn, against the box the layout reserves for it. Printed per
/// row (`EMOJI-PROBE …`) and shown on screen.
///
/// ```bash
/// flutter run -d <device> -t lib/main_emoji_probe.dart
/// ```
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

void main() => runApp(const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: _Probe(),
    ));

/// The styles text meets emoji in: the bubble (bodyMedium), the caption, and
/// the composer (bodyLarge). Height and letter spacing as Material 3 sets them.
class _Case {
  const _Case(this.name, this.size, this.height, this.spacing);

  final String name;
  final double size;
  final double? height;
  final double spacing;
}

const _cases = [
  _Case('bubble', 14, 1.43, 0.25),
  _Case('caption', 15, null, 0),
  _Case('composer', 16, 1.5, 0.5),
];

const _factors = [1.0, 1.125, 1.25, 1.35, 1.5];

class _Row {
  _Row(this.label, this.values);

  final String label;
  final Map<String, double> values;

  String get line => 'EMOJI-PROBE $label '
      '${values.entries.map((e) => '${e.key}=${e.value.toStringAsFixed(2)}').join(' ')}';
}

class _Probe extends StatefulWidget {
  const _Probe();

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  final _rows = <_Row>[];
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    try {
      // At the first frame Android may still report a ratio of 1.0; the real
      // one arrives with the window metrics a moment later. Measured at 1.0,
      // the ink is only resolved to whole logical pixels.
      var dpr = 1.0;
      for (var i = 0; i < 40 && dpr <= 1.0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (!mounted) return;
        dpr = View.of(context).devicePixelRatio;
      }
      final fonts = <String, TextStyle>{
        'system': const TextStyle(),
        'nunito': GoogleFonts.nunito(),
      };
      // Let google_fonts fetch before measuring; a failed fetch falls back to
      // the system font, which the label then says.
      await GoogleFonts.pendingFonts();
      for (final font in fonts.entries) {
        for (final c in _cases) {
          final base = font.value.copyWith(
            fontSize: c.size,
            height: c.height,
            letterSpacing: c.spacing,
            color: Colors.black,
          );
          for (final f in _factors) {
            final row = await _measure(base, f, dpr);
            debugPrint(row.copyWithLabel('${font.key} ${c.name} x$f').line);
            setState(() => _rows.add(row.copyWithLabel('${font.key} ${c.name} x$f')));
          }
        }
      }
      debugPrint('EMOJI-PROBE done dpr=$dpr');
    } catch (e, st) {
      debugPrint('EMOJI-PROBE error $e\n$st');
      setState(() => _error = '$e');
    }
  }

  /// Lays out „🙂“ with the emoji at [factor] × the base size, the way the
  /// bubble splits it into spans, and measures box and ink.
  Future<_Row> _measure(TextStyle base, double factor, double dpr) async {
    final emoji = base.copyWith(fontSize: base.fontSize! * factor);
    final span = TextSpan(style: base, children: [
      const TextSpan(text: '„'),
      TextSpan(text: '\u{1F642}', style: emoji),
      const TextSpan(text: '“'),
    ]);
    final tp = TextPainter(text: span, textDirection: TextDirection.ltr)
      ..layout();
    // Code units: „ = 0, 🙂 = 1..2, “ = 3.
    final box = tp
        .getBoxesForSelection(const TextSelection(baseOffset: 1, extentOffset: 3))
        .first;
    final plain = TextPainter(
      text: TextSpan(text: 'Hallo', style: base),
      textDirection: TextDirection.ltr,
    )..layout();

    // Two ways to keep the line as tall as plain text: the emoji span's own
    // height scaled down by the size factor, or a strut that fixes the line.
    final fixedHeight = base.height == null
        ? null
        : base.copyWith(
            fontSize: emoji.fontSize,
            height: base.height! / factor,
          );
    final perSpan = fixedHeight == null
        ? null
        : (TextPainter(
            text: TextSpan(style: base, children: [
              const TextSpan(text: '\u201E'),
              TextSpan(text: '\u{1F642}', style: fixedHeight),
              const TextSpan(text: '\u201C'),
            ]),
            textDirection: TextDirection.ltr,
          )..layout());
    final strut = TextPainter(
      text: span,
      textDirection: TextDirection.ltr,
      strutStyle: StrutStyle.fromTextStyle(base, forceStrutHeight: true),
    )..layout();

    final ink = await _inkColumns(tp, dpr);
    // Ink runs left to right; the emoji is the widest one.
    final runs = <(double, double)>[];
    double? start;
    for (var x = 0; x < ink.length; x++) {
      if (ink[x] && start == null) start = x.toDouble();
      if (!ink[x] && start != null) {
        runs.add((start, x.toDouble()));
        start = null;
      }
    }
    if (start != null) runs.add((start, ink.length.toDouble()));
    var e = 0;
    for (var i = 1; i < runs.length; i++) {
      if (runs[i].$2 - runs[i].$1 > runs[e].$2 - runs[e].$1) e = i;
    }
    final inkL = runs.isEmpty ? 0.0 : runs[e].$1 / dpr;
    final inkR = runs.isEmpty ? 0.0 : runs[e].$2 / dpr;
    final gapBefore = e > 0 ? (runs[e].$1 - runs[e - 1].$2) / dpr : -1.0;
    final gapAfter =
        e + 1 < runs.length ? (runs[e + 1].$1 - runs[e].$2) / dpr : -1.0;
    final inkV = await _inkRows(tp, dpr, box.left, box.right);

    return _Row('', {
      'size': emoji.fontSize!,
      'boxL': box.left,
      'boxW': box.right - box.left,
      'inkL': inkL,
      'inkW': inkR - inkL,
      'trail': box.right - inkR,
      'gapBefore': gapBefore,
      'gapAfter': gapAfter,
      'inkTop': inkV.$1,
      'inkH': inkV.$2 - inkV.$1,
      'lineText': plain.height,
      'lineEmoji': tp.height,
      'linePerSpan': perSpan?.height ?? -1,
      'lineStrut': strut.height,
      'baseline': tp.computeLineMetrics().first.baseline,
    });
  }

  Future<ui.Image> _paint(TextPainter tp, double dpr) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(dpr);
    tp.paint(canvas, Offset.zero);
    return recorder.endRecording().toImage(
          (tp.width * dpr).ceil() + 2,
          (tp.height * dpr).ceil() + 2,
        );
  }

  Future<List<bool>> _inkColumns(TextPainter tp, double dpr) async {
    final img = await _paint(tp, dpr);
    final data = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    final cols = List<bool>.filled(img.width, false);
    for (var x = 0; x < img.width; x++) {
      for (var y = 0; y < img.height; y++) {
        if (data.getUint8((y * img.width + x) * 4 + 3) > 24) {
          cols[x] = true;
          break;
        }
      }
    }
    return cols;
  }

  /// Top and bottom of the ink between [left] and [right] (the emoji's box).
  Future<(double, double)> _inkRows(
      TextPainter tp, double dpr, double left, double right) async {
    final img = await _paint(tp, dpr);
    final data = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    int? top, bottom;
    for (var y = 0; y < img.height; y++) {
      for (var x = (left * dpr).floor(); x < (right * dpr).ceil(); x++) {
        if (x < 0 || x >= img.width) continue;
        if (data.getUint8((y * img.width + x) * 4 + 3) > 24) {
          top ??= y;
          bottom = y;
          break;
        }
      }
    }
    return ((top ?? 0) / dpr, ((bottom ?? 0) + 1) / dpr);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            for (final c in _cases)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(text: '${c.name}: mit „'),
                    TextSpan(
                      text: '\u{1F642}',
                      style: TextStyle(fontSize: c.size * 1.125),
                    ),
                    const TextSpan(text: '“ reagiert'),
                  ]),
                  style: TextStyle(
                    fontSize: c.size,
                    height: c.height,
                    letterSpacing: c.spacing,
                  ),
                ),
              ),
            if (_error != null) Text('error: $_error'),
            for (final r in _rows)
              Text(r.line.replaceFirst('EMOJI-PROBE ', ''),
                  style: const TextStyle(fontSize: 10, fontFamily: 'monospace')),
          ],
        ),
      ),
    );
  }
}

extension on _Row {
  _Row copyWithLabel(String label) => _Row(label, values);
}
