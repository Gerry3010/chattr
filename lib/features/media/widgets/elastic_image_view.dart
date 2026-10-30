// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Where an image may sit inside a viewport, and how far a finger may pull it
/// past that (CHAT-55/56).
///
/// Scale 1 is "fits the screen" (`BoxFit.contain`). At rest an image is never
/// smaller than that, never zoomed beyond [maxScale], and never leaves a black
/// gap on a side it is large enough to cover; on a side it is too small for, it
/// sits centred. While the fingers are down it may go a [slack] further on
/// every side and down to [minGestureScale]; letting go springs back.
@visibleForTesting
class ElasticBounds {
  ElasticBounds({
    required this.viewport,
    required this.imageSize,
    this.minGestureScale = 0.75,
    double? slack,
  }) : slack = slack ?? viewport.shortestSide * 0.15 {
    final fit = math.min(
      viewport.width / imageSize.width,
      viewport.height / imageSize.height,
    );
    fitted = Size(imageSize.width * fit, imageSize.height * fit);
    origin = Offset(
      (viewport.width - fitted.width) / 2,
      (viewport.height - fitted.height) / 2,
    );
    coverScale = math.max(
      viewport.width / fitted.width,
      viewport.height / fitted.height,
    );
    maxScale = math.max(3, coverScale * 3);
  }

  final Size viewport;
  final Size imageSize;
  final double minGestureScale;
  final double slack;

  /// The image at scale 1, inside the viewport.
  late final Size fitted;
  late final Offset origin;

  /// The scale at which the image fills the whole viewport.
  late final double coverScale;
  late final double maxScale;

  /// Range of the translation on one axis for [scale], widened by [extra].
  (double, double) _range(double view, double size, double origin, double scale,
      double extra) {
    final scaled = size * scale;
    if (scaled <= view) {
      final centred = (view - scaled) / 2 - origin * scale;
      return (centred - extra, centred + extra);
    }
    return (view - scaled - origin * scale - extra, -origin * scale + extra);
  }

  Offset _clamp(Offset t, double scale, double extra) {
    final (minX, maxX) =
        _range(viewport.width, fitted.width, origin.dx, scale, extra);
    final (minY, maxY) =
        _range(viewport.height, fitted.height, origin.dy, scale, extra);
    return Offset(t.dx.clamp(minX, maxX), t.dy.clamp(minY, maxY));
  }

  /// Where the image may be while the fingers are down.
  Matrix4 duringGesture(Matrix4 m) {
    final scale = m.getMaxScaleOnAxis();
    final t = _clamp(_translation(m), scale, slack);
    return _compose(scale, t);
  }

  /// Where the image settles once the fingers are up.
  Matrix4 atRest(Matrix4 m) {
    final scale = m.getMaxScaleOnAxis().clamp(1.0, maxScale);
    if (scale == m.getMaxScaleOnAxis()) {
      return _compose(scale, _clamp(_translation(m), scale, 0));
    }
    // Scaled back from a pinch beyond the limits: keep the point under the
    // middle of the screen where it was.
    final current = m.getMaxScaleOnAxis();
    final centre = viewport.center(Offset.zero);
    final scene = (centre - _translation(m)) / current;
    return _compose(scale, _clamp(centre - scene * scale, scale, 0));
  }

  /// Double tap: zoom in around [focus], or back to fit when zoomed already.
  Matrix4 toggle(Matrix4 m, Offset focus) {
    final current = m.getMaxScaleOnAxis();
    if (current > 1.01) return Matrix4.identity();
    final target = math.max(2.5, coverScale);
    final scene = (focus - _translation(m)) / current;
    return _compose(target, _clamp(focus - scene * target, target, 0));
  }

  static Offset _translation(Matrix4 m) {
    final t = m.getTranslation();
    return Offset(t.x, t.y);
  }

  static Matrix4 _compose(double scale, Offset t) => Matrix4.identity()
    ..translateByDouble(t.dx, t.dy, 0, 1)
    ..scaleByDouble(scale, scale, 1, 1);
}

/// A zoomable full-screen image that springs back (CHAT-55/56).
///
/// Built on [InteractiveViewer] rather than photo_view: photo_view clamps the
/// image to its edges on every move and cannot go below "fits", so it felt
/// stiff; a bare InteractiveViewer with an infinite boundary (the old avatar
/// viewer) went the other way and let the picture be dragged out of sight.
/// Here the fingers get a little slack in every direction and the picture
/// settles back when they let go.
class ElasticImageView extends StatefulWidget {
  const ElasticImageView({
    super.key,
    required this.image,
    this.onZoomChanged,
    this.heroTag,
  });

  final ImageProvider image;

  /// True while zoomed in (or pinching), false at rest. The swipe-down dismiss
  /// and gallery paging listen to this.
  final ValueChanged<bool>? onZoomChanged;

  final Object? heroTag;

  @override
  State<ElasticImageView> createState() => _ElasticImageViewState();
}

class _ElasticImageViewState extends State<ElasticImageView>
    with SingleTickerProviderStateMixin {
  final _transform = TransformationController();
  late final AnimationController _spring = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  )..addListener(_onSpringTick);
  Animation<Matrix4>? _springAnimation;

  ImageStream? _stream;
  ImageStreamListener? _listener;
  Size? _imageSize;
  ElasticBounds? _bounds;
  Offset _doubleTapAt = Offset.zero;
  bool _zoomed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(ElasticImageView old) {
    super.didUpdateWidget(old);
    if (old.image != widget.image) {
      _imageSize = null;
      _transform.value = Matrix4.identity();
      _resolve();
    }
  }

  void _resolve() {
    final stream = widget.image.resolve(createLocalImageConfiguration(context));
    if (stream.key == _stream?.key) return;
    _unlisten();
    _stream = stream;
    _listener = ImageStreamListener((info, _) {
      final size =
          Size(info.image.width.toDouble(), info.image.height.toDouble());
      info.dispose();
      if (mounted && size != _imageSize) setState(() => _imageSize = size);
    });
    stream.addListener(_listener!);
  }

  void _unlisten() {
    if (_listener != null) _stream?.removeListener(_listener!);
    _listener = null;
  }

  @override
  void dispose() {
    _unlisten();
    _spring.dispose();
    _transform.dispose();
    super.dispose();
  }

  void _report() {
    final zoomed = (_transform.value.getMaxScaleOnAxis() - 1).abs() > 0.01;
    if (zoomed == _zoomed) return;
    _setZoomed(zoomed);
  }

  void _setZoomed(bool zoomed) {
    if (!mounted) return;
    setState(() => _zoomed = zoomed);
    widget.onZoomChanged?.call(zoomed);
  }

  void _onSpringTick() {
    final a = _springAnimation;
    if (a != null) _transform.value = a.value;
    if (_spring.isCompleted) _report();
  }

  void _springTo(Matrix4 target) {
    _springAnimation = Matrix4Tween(begin: _transform.value, end: target)
        .animate(CurvedAnimation(parent: _spring, curve: Curves.easeOutCubic));
    _spring
      ..value = 0
      ..forward();
  }

  void _onStart(ScaleStartDetails d) {
    _spring.stop();
    // A pinch counts as zoomed from its first moment, so neither the
    // swipe-down dismiss nor the gallery takes it over halfway. One finger at
    // rest is left to them: panning is off until the picture is zoomed.
    if (!_zoomed && d.pointerCount > 1) _setZoomed(true);
  }

  void _onUpdate(ScaleUpdateDetails _) {
    final b = _bounds;
    if (b == null) return;
    _transform.value = b.duringGesture(_transform.value);
  }

  void _onEnd(ScaleEndDetails _) {
    final b = _bounds;
    if (b == null) return;
    _springTo(b.atRest(_transform.value));
  }

  void _onDoubleTap() {
    final b = _bounds;
    if (b == null) return;
    _springTo(b.toggle(_transform.value, _doubleTapAt));
  }

  @override
  Widget build(BuildContext context) {
    Widget image = Image(
      image: widget.image,
      fit: BoxFit.contain,
      gaplessPlayback: true,
    );
    if (widget.heroTag != null) {
      image = Hero(tag: widget.heroTag!, child: image);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = constraints.biggest;
        final size = _imageSize;
        _bounds = size == null || size.isEmpty || viewport.isEmpty
            ? null
            : ElasticBounds(viewport: viewport, imageSize: size);
        return GestureDetector(
          onDoubleTapDown: (d) => _doubleTapAt = d.localPosition,
          onDoubleTap: _onDoubleTap,
          child: InteractiveViewer(
            transformationController: _transform,
            minScale: _bounds?.minGestureScale ?? 1,
            maxScale: _bounds?.maxScale ?? 1,
            // Bounds are enforced here, with slack, not by the viewer.
            boundaryMargin: const EdgeInsets.all(double.infinity),
            panEnabled: _zoomed,
            clipBehavior: Clip.none,
            // No fling: the spring back is the only motion after letting go.
            interactionEndFrictionCoefficient: 1e-300,
            onInteractionStart: _onStart,
            onInteractionUpdate: _onUpdate,
            onInteractionEnd: _onEnd,
            child: SizedBox.expand(child: image),
          ),
        );
      },
    );
  }
}
