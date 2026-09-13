// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:camera/camera.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';

import '../../../core/logging/logger_service.dart';
import '../media_attachment.dart';
import 'camera_capture_mode.dart';
import 'camera_launcher.dart';
import 'camera_zoom.dart';

/// Our own camera — preview, shutter, mode.
///
/// **Why it exists.** Until now the app handed over to the phone's camera app
/// (`image_picker`). Its shutter, its video mode, its "retake/use" screen —
/// none of it was ours, so none of it could be changed. That is why the gesture
/// "tap = photo, hold = video" sat on the tile in the attachment sheet, where
/// nobody looks for it.
///
/// Here the rule is: **what gets captured goes straight into the send sheet.**
/// No intermediate screen asking whether that is alright — the preview with its
/// send button is the next step anyway.
class ChattrCameraScreen extends StatefulWidget {
  const ChattrCameraScreen({
    super.key,
    required this.cameras,
    this.initialShot = true,
  });

  final List<CameraDescription> cameras;

  /// Default of the shot switch. The tile is called "Shot", so it starts on.
  final bool initialShot;

  @override
  State<ChattrCameraScreen> createState() => _ChattrCameraScreenState();
}

class _ChattrCameraScreenState extends State<ChattrCameraScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  int _cameraIndex = 0;
  bool _ready = false;

  /// What the shutter means — the entire gesture logic lives here and not in
  /// the UI's callbacks.
  final _shutter = CameraShutter();

  late bool _asShot = widget.initialShot;

  /// Locks the shutter while a capture is being written. Without it a second
  /// tap triggers a second photo while the first is still on its way.
  bool _busy = false;

  FlashMode _flash = FlashMode.off;

  Timer? _clock;
  Duration _elapsed = Duration.zero;

  /// What the device offers in the way of zoom — asked at startup, not assumed.
  CameraZoomRange _zoomRange = CameraZoomRange.none;

  /// The current level — as a [ValueNotifier], **not** as a field with
  /// `setState`. While zooming, one report arrives per frame; a `setState`
  /// rebuilt the whole screen each time, preview, shutter and both
  /// `AnimatedContainer`s included. That was exactly the stutter. This way only
  /// the number itself is listening.
  final _zoom = ValueNotifier<double>(1);

  /// The level at the moment the fingers touched down. Without it every report
  /// of the gesture multiplies again and the zoom shoots to the end on the
  /// first tug.
  double _zoomBase = 1;

  /// Where the gesture wants to go, and what the camera was last actually set
  /// to.
  ///
  /// **Why two values.** The gesture reports at frame rate; the camera needs
  /// longer than that for one level. Waiting on each report individually
  /// delivers only a dozen **large jumps** per second — and those then sit in
  /// the recorded video, not just in the preview. The pump below decouples the
  /// two: it eases towards the target at a fixed rate.
  double _zoomTarget = 1;
  double _zoomSent = 1;
  Timer? _zoomPump;

  Timer? _zoomHideTimer;
  final _zoomVisible = ValueNotifier<bool>(false);

  /// While the drag on the shutter continues, the readout stays put — even if
  /// the finger holds still for a moment.
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _cameraIndex = _backCameraIndex();
    unawaited(_start());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clock?.cancel();
    _zoomHideTimer?.cancel();
    _zoomPump?.cancel();
    _zoom.dispose();
    _zoomVisible.dispose();
    _controller?.dispose();
    super.dispose();
  }

  /// The camera has to be released when the app is left — otherwise Chattr
  /// holds on to it and the next app gets a black picture.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      // A running recording counts as lost: the system ends it anyway, and a
      // state machine that still believes it is "running" blocks the shutter
      // afterwards.
      _shutter.reset();
      _clock?.cancel();
      _controller = null;
      setState(() => _ready = false);
      unawaited(c.dispose());
    } else if (state == AppLifecycleState.resumed) {
      unawaited(_start());
    }
  }

  int _backCameraIndex() {
    final i = widget.cameras.indexWhere(
        (c) => c.lensDirection == CameraLensDirection.back);
    return i >= 0 ? i : 0;
  }

  /// Photos at the highest resolution, video at a dependable one.
  ///
  /// A photo should not get worse just because it now comes from our own view —
  /// up to now the camera app delivered the full sensor resolution. For video
  /// the calculation is the other way round: `max` means 4K on some devices,
  /// and what comes of that is more of a problem for the size limit than a
  /// gain.
  ResolutionPreset get _resolution => _shutter.mode == CaptureMode.video
      ? ResolutionPreset.veryHigh
      : ResolutionPreset.max;

  Future<void> _start() async {
    if (_controller != null) return;
    final description = widget.cameras[_cameraIndex];
    final c = CameraController(
      description,
      _resolution,
      // Sound belongs to video. On Android that hangs on RECORD_AUDIO — without
      // the permission in the manifest the device records silently or fails
      // depending on the model, and either way it only shows up on playback.
      enableAudio: true,
    );
    _controller = c;
    try {
      await c.initialize();
      await _setFlash(c, _flash);
      await _learnZoomRange(c);
      if (!mounted) return;
      setState(() => _ready = true);
    } on CameraException catch (e) {
      logger.warning('Kamera nicht startbar: ${e.code}', tag: 'Camera');
      _controller = null;
      if (!mounted) return;
      _notify(_isDenied(e)
          ? 'media.camera_denied'.tr()
          : 'camera.unavailable'.tr());
      Navigator.of(context).pop();
    }
  }

  bool _isDenied(CameraException e) {
    final code = e.code.toLowerCase();
    return code.contains('denied') || code.contains('permission');
  }

  Future<void> _setFlash(CameraController c, FlashMode mode) async {
    try {
      await c.setFlashMode(mode);
    } on CameraException catch (e) {
      // Not every camera can do every flash mode. That is no reason to refuse
      // the capture.
      logger.debug('Blitzmodus $mode abgelehnt: ${e.code}', tag: 'Camera');
    }
  }

  /// Ask the currently running camera for its zoom range and clamp the previous
  /// level into it.
  ///
  /// **No reason to let the camera fail.** If a device reports an error here,
  /// [CameraZoomRange.none] stays in place — then there is no zoom, but there
  /// very much is a camera.
  Future<void> _learnZoomRange(CameraController c) async {
    try {
      final range = CameraZoomRange.fromDevice(
        min: await c.getMinZoomLevel(),
        max: await c.getMaxZoomLevel(),
      );
      final level = range.clamp(_zoom.value);
      if (level != 1) await c.setZoomLevel(level);
      _zoomRange = range;
      _zoom.value = level;
      _zoomTarget = level;
      _zoomSent = level;
      logger.debug(
          'Zoom-Spanne ${range.min}x bis ${range.max}x', tag: 'Camera');
    } on CameraException catch (e) {
      logger.debug('Zoom nicht abfragbar: ${e.code}', tag: 'Camera');
      _zoomRange = CameraZoomRange.none;
      _zoom.value = 1;
      _zoomTarget = 1;
      _zoomSent = 1;
    }
  }

  /// **Want** a new level. Delivering it is the pump's job.
  ///
  /// No `setState` — the hot path of a zoom gesture must not rebuild the
  /// screen.
  void _setZoom(double level) {
    if (level == _zoomTarget) return;
    _zoomTarget = level;
    _zoomVisible.value = true;
    _scheduleZoomHide();
    _startZoomPump();
  }

  void _scheduleZoomHide() {
    _zoomHideTimer?.cancel();
    if (_dragging) return;
    _zoomHideTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) _zoomVisible.value = false;
    });
  }

  /// The pump: eases towards the wanted level at a fixed rate.
  ///
  /// **Why not simply await every report.** `setZoomLevel` only counts as done
  /// once the camera has really taken the level on — that takes frames. Waiting
  /// on it delivers a dozen large jumps per second, and because zoom is a real
  /// change to the picture, **those jumps sit in the recorded video**.
  /// Smoothing the preview would have healed none of it.
  ///
  /// So they are separated: the pump runs at frame rate, fires **without
  /// waiting** and approaches the target in small steps ([_zoomEasing] per
  /// tick). That also smooths the tremor of the finger — a small delay nobody
  /// sees, against steps everybody does. It stops as soon as it has arrived;
  /// nothing idles.
  static const double _zoomEasing = 0.35;

  void _startZoomPump() {
    _zoomPump ??= Timer.periodic(const Duration(milliseconds: 16), (t) {
      final c = _controller;
      if (!mounted || c == null || !_ready) {
        t.cancel();
        _zoomPump = null;
        return;
      }
      final rest = _zoomTarget - _zoomSent;
      if (rest.abs() < 0.002) {
        _zoomSent = _zoomTarget;
        _zoom.value = _zoomTarget;
        t.cancel();
        _zoomPump = null;
        return;
      }
      _zoomSent += rest * _zoomEasing;
      // The readout shows what the camera is set to — not where the finger has
      // already dragged to. Otherwise the number runs ahead of the picture.
      _zoom.value = _zoomSent;
      unawaited(c.setZoomLevel(_zoomSent).catchError((Object _) {}));
    });
  }

  void _pinchStart() => _zoomBase = _zoomTarget;

  void _pinchUpdate(double scale) {
    if (!_ready || !_zoomRange.available) return;
    _setZoom(
        zoomFromPinch(range: _zoomRange, base: _zoomBase, scale: scale));
  }

  // ------------------------------------------------- Ziehen am Ausloeser

  /// From here the distance counts — before it lies the shutter itself (radius
  /// 38) plus some room for the tremor of the finger.
  static const double _dragThreshold = 56;

  /// The whole zoom range runs through over this distance.
  ///
  /// `shortestSide` and not the height: in landscape the height would suddenly
  /// be the short side, and the same finger movement would mean something else.
  /// The short side is the same distance in both orientations.
  double get _dragSpan =>
      (MediaQuery.sizeOf(context).shortestSide * 0.55).clamp(140.0, 320.0);

  void _dragStart() {
    _dragging = true;
    _zoomBase = _zoomTarget;
  }

  void _dragUpdate(double distance) {
    if (!_ready || !_zoomRange.available) return;
    _setZoom(zoomFromDrag(
      range: _zoomRange,
      distance: distance,
      threshold: _dragThreshold,
      span: _dragSpan,
      start: _zoomBase,
    ));
  }

  void _dragEnd() {
    _dragging = false;
    _scheduleZoomHide();
  }

  bool get _hasFlash =>
      widget.cameras[_cameraIndex].lensDirection != CameraLensDirection.front;

  // ---------------------------------------------------------------- Aktionen

  Future<void> _perform(ShutterAction aktion) async {
    switch (aktion) {
      case ShutterAction.none:
        return;
      case ShutterAction.takePhoto:
        await _takePhoto();
      case ShutterAction.startVideo:
        await _startVideo();
      case ShutterAction.stopVideo:
        await _stopVideo();
    }
  }

  Future<void> _takePhoto() async {
    final c = _controller;
    if (c == null || !_ready || _busy) return;
    setState(() => _busy = true);
    try {
      final file = await c.takePicture();
      _finish(file);
    } on CameraException catch (e) {
      logger.warning('Foto fehlgeschlagen: ${e.code}', tag: 'Camera');
      if (mounted) {
        setState(() => _busy = false);
        _notify('camera.capture_error'.tr());
      }
    }
  }

  Future<void> _startVideo() async {
    final c = _controller;
    if (c == null || !_ready || _busy) {
      _shutter.reset();
      return;
    }
    try {
      await c.startVideoRecording();
      // Torch instead of flash: a flash lights one moment, a video needs
      // continuous light. If it fails, the recording carries on regardless.
      if (_flash != FlashMode.off) await _setFlash(c, FlashMode.torch);
      _elapsed = Duration.zero;
      _clock?.cancel();
      _clock = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() => _elapsed += const Duration(seconds: 1));
      });
      if (mounted) setState(() {});
    } on CameraException catch (e) {
      logger.warning('Videoaufnahme nicht startbar: ${e.code}', tag: 'Camera');
      _shutter.reset();
      if (mounted) {
        setState(() {});
        _notify('camera.capture_error'.tr());
      }
    }
  }

  Future<void> _stopVideo() async {
    final c = _controller;
    _clock?.cancel();
    if (c == null || !c.value.isRecordingVideo) {
      _shutter.reset();
      if (mounted) setState(() {});
      return;
    }
    setState(() => _busy = true);
    try {
      final file = await c.stopVideoRecording();
      await _setFlash(c, _flash);
      _finish(file);
    } on CameraException catch (e) {
      logger.warning('Videoaufnahme nicht beendbar: ${e.code}', tag: 'Camera');
      _shutter.reset();
      if (mounted) {
        setState(() => _busy = false);
        _notify('camera.capture_error'.tr());
      }
    }
  }

  /// Capture done — **straight back**, no intermediate screen.
  void _finish(XFile file) {
    if (!mounted) return;
    final extension = file.path.split('.').last;
    Navigator.of(context).pop(CameraCapture(
      path: file.path,
      fileName: file.name.isEmpty ? 'chattr.$extension' : file.name,
      mime: file.mimeType ?? mimeForExtension(extension),
      asShot: _asShot,
    ));
  }

  void _notify(String text) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _switchCamera() async {
    if (widget.cameras.length < 2 || _shutter.isRecording || _busy) {
      return;
    }
    final previous = _controller;
    _controller = null;
    setState(() => _ready = false);
    await previous?.dispose();
    _cameraIndex = (_cameraIndex + 1) % widget.cameras.length;
    await _start();
  }

  Future<void> _switchMode(CaptureMode mode) async {
    if (!_shutter.setMode(mode)) return;
    // The resolution hangs on the mode, and a preset cannot be changed while
    // running — so set up once more from scratch.
    final previous = _controller;
    _controller = null;
    setState(() => _ready = false);
    await previous?.dispose();
    await _start();
  }

  Future<void> _cycleFlash() async {
    const order = [FlashMode.off, FlashMode.auto, FlashMode.always];
    final next = order[(order.indexOf(_flash) + 1) % order.length];
    setState(() => _flash = next);
    final c = _controller;
    if (c != null) {
      await _setFlash(
          c, _shutter.isRecording && next != FlashMode.off
              ? FlashMode.torch
              : next);
    }
  }

  // ------------------------------------------------------------------ Aufbau

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // The pinch gesture sits **beneath** the controls: the shutter above
          // gets its touches first, so a long press on it is never read as a
          // zoom.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onScaleStart: (_) => _pinchStart(),
            onScaleUpdate: (d) {
              // A single finger reports here too (with scale 1.0) — that would
              // be a swipe, not a zoom.
              if (d.pointerCount < 2) return;
              _pinchUpdate(d.scale);
            },
            child: _ready && c != null
                ? Center(child: _preview(c))
                : const Center(
                    child: CircularProgressIndicator(color: Colors.white70)),
          ),
          SafeArea(child: _controls(c)),
        ],
      ),
    );
  }

  /// How the preview sits while a recording started from **photo mode** is
  /// running — as an **absolute** number, not as an increment.
  ///
  /// Measured on the device (Galaxy A26, 2026-09-04): in portrait as in
  /// landscape the same fixed rotation is correct. That fits the cause: CameraX
  /// rebinds the preview to a fixed target rotation when the recorder is
  /// attached, so the orientation of the device no longer contributes anything.
  static const int _holdRecordingTurns = 3;

  /// The preview.
  ///
  /// Three faults lay on top of each other here, each hiding the next. In order,
  /// because otherwise nobody understands why there is a rotation here that "per
  /// the package" is not needed:
  ///
  /// 1. `controller.buildPreview()` returns no raw image on Android but a
  ///    `RotatedPreviewDelegate`. It rotates by
  ///    `display rotation − rotation CameraPreview is about to apply`.
  ///    So it **presupposes** that somebody supplies the second half. That is
  ///    exactly what [previewQuarterTurns] does — and that is why this rotation
  ///    is not a hack but the missing part of an equation.
  /// 2. `CameraPreview` from the package would do it too, but during a recording
  ///    it draws the rotation from `recordingOrientation` — a snapshot taken at
  ///    the start that does not match the orientation on the Galaxy. Hence
  ///    `deviceOrientation` here, always.
  /// 3. A remainder is left, and it is **narrower than assumed**: only a recording
  ///    started from **photo mode** (long press) tips over, one from video mode
  ///    does not. That is precisely what Gerry pointed out — "in the video screen
  ///    it works, only on the long press it doesn't" — and it follows from
  ///    [_resolution]: photo mode binds the camera with `ResolutionPreset.max`,
  ///    video mode with `veryHigh`. If the video recorder attaches to a preview
  ///    bound for photos, CameraX rebinds it and turns the texture by a quarter
  ///    turn in the process. Whoever is already in video mode has the matching
  ///    binding — nothing happens there.
  ///
  ///    Measured on the device (Galaxy A26, 2026-09-04, rig): at rest +0,
  ///    video-mode recording +0, **long press +3**. That is why the counter
  ///    rotation hangs on exactly this condition and not on `isRecordingVideo`
  ///    alone — that was the fault in 1.29.1, and it dragged landscape down with
  ///    it.
  ///
  /// All numbers here are **measured**, not derived — see [previewQuarterTurns] and
  /// `lib/main_camera_probe.dart`. Deriving fails because Android's
  /// `Surface.ROTATION_*` and Flutter's `DeviceOrientation` name the same rotation
  /// in opposite directions; two plausible derivations give opposite answers.
  Widget _preview(CameraController c) => ValueListenableBuilder<CameraValue>(
        valueListenable: c,
        builder: (context, value, _) {
          final orientation =
              value.lockedCaptureOrientation ?? value.deviceOrientation;
          final android =
              !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
          var turns = android ? previewQuarterTurns(orientation) : 0;
          // Only the long press: recording on a preview bound for photos. In
          // video mode the binding is already right.
          //
          // **Absolute, not added.** When the recorder is attached, CameraX
          // rebinds the preview to a FIXED target rotation — from then on the
          // orientation of the device no longer counts. Computed additively,
          // only portrait was right (where the orientation happens to
          // contribute zero) and landscape was off by two.
          if (android &&
              value.isRecordingVideo &&
              _shutter.mode == CaptureMode.photo) {
            turns = android ? _holdRecordingTurns : 0;
          }
          // **The outer frame hangs on the device orientation alone.** It
          // describes how the finished picture should sit on screen — not how
          // often things are rotated inside. Folding the counter rotation
          // during recording into it was exactly the fault: the upright
          // viewfinder turned into a wide band the moment recording started,
          // with the picture squeezed inside it.
          final landscape = previewIsLandscape(orientation);
          final ratio = landscape ? value.aspectRatio : 1 / value.aspectRatio;
          return AspectRatio(
            aspectRatio: ratio,
            child: RotatedBox(quarterTurns: turns, child: c.buildPreview()),
          );
        },
      );

  Widget _topBar() => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.close, color: Colors.white),
              tooltip: 'shots.close'.tr(),
              onPressed: _shutter.isRecording
                  ? null
                  : () => Navigator.of(context).pop(),
            ),
            const Spacer(),
            _shotToggle(),
            const Spacer(),
            if (_hasFlash)
              IconButton(
                icon: Icon(_flashIcon, color: Colors.white),
                tooltip: 'camera.flash'.tr(),
                onPressed: _cycleFlash,
              )
            else
              const SizedBox(width: 48),
          ],
        ),
      );

  IconData get _flashIcon => switch (_flash) {
        FlashMode.always => Icons.flash_on,
        FlashMode.auto => Icons.flash_auto,
        _ => Icons.flash_off,
      };

  /// Shot or normal — the decision that makes this camera the "Shot" tile in
  /// the first place. It can still be flipped in the send sheet.
  Widget _shotToggle() {
    final colors = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: _shutter.isRecording
          ? null
          : () => setState(() => _asShot = !_asShot),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: _asShot ? colors.primary : Colors.white24,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_asShot ? Icons.timer : Icons.timer_off_outlined,
                size: 16,
                color: _asShot ? colors.onPrimary : Colors.white),
            const SizedBox(width: 6),
            Text(
              _asShot ? 'camera.shot_mode'.tr() : 'camera.normal_mode'.tr(),
              style: TextStyle(
                color: _asShot ? colors.onPrimary : Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _elapsedBadge() {
    final m = _elapsed.inMinutes.toString().padLeft(2, '0');
    final s = (_elapsed.inSeconds % 60).toString().padLeft(2, '0');
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.fiber_manual_record, color: Colors.red, size: 12),
          const SizedBox(width: 6),
          Text('$m:$s',
              style: const TextStyle(
                  color: Colors.white, fontFeatures: [FontFeature.tabularFigures()])),
        ],
      ),
    );
  }

  /// The zoom level, while pinching and shortly after.
  ///
  /// It **always** occupies its place (`AnimatedOpacity` rather than a tile
  /// that comes and goes), otherwise the whole control bar hopped downwards on
  /// the first tug.
  Widget _zoomBadge() => IgnorePointer(
        child: ValueListenableBuilder<bool>(
          valueListenable: _zoomVisible,
          builder: (_, visible, child) => AnimatedOpacity(
            duration: const Duration(milliseconds: 200),
            opacity: visible ? 1 : 0,
            child: child,
          ),
          child: Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(16),
            ),
            child: ValueListenableBuilder<double>(
              valueListenable: _zoom,
              builder: (_, level, _) => Text(
                zoomLabel(level, context.locale.toString()),
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
        ),
      );

  /// The controls sit on the **device edge with the port** — at the bottom in
  /// portrait, at the side in landscape.
  ///
  /// The interface rotates along (no orientation lock), so in landscape the
  /// bottom edge of the screen wanders to the long edge of the device — where
  /// the hand happens not to be. [controlEdgeFor] decides.
  Widget _controls(CameraController? c) {
    if (c == null || !_ready) return _controlsFor(ControlEdge.bottom);
    return ValueListenableBuilder<CameraValue>(
      valueListenable: c,
      builder: (_, value, _) => _controlsFor(controlEdgeFor(
          value.lockedCaptureOrientation ?? value.deviceOrientation)),
    );
  }

  Widget _controlsFor(ControlEdge padding) {
    final landscape = padding != ControlEdge.bottom;
    final center = Column(
      children: [
        _topBar(),
        const Spacer(),
        if (_shutter.isRecording) _elapsedBadge(),
        _zoomBadge(),
        if (!landscape) _controlBar(landscape: false),
      ],
    );
    if (!landscape) return center;
    final bar = _controlBar(landscape: true);
    return Row(
      children: [
        if (padding == ControlEdge.left) bar,
        Expanded(child: center),
        if (padding == ControlEdge.right) bar,
      ],
    );
  }

  Widget _switchCameraButton() => SizedBox(
        width: 48,
        height: 48,
        child: widget.cameras.length > 1
            ? IconButton(
                icon: const Icon(Icons.cameraswitch, color: Colors.white),
                tooltip: 'camera.switch'.tr(),
                onPressed: _shutter.isRecording ? null : _switchCamera,
              )
            : null,
      );

  Widget _controlBar({required bool landscape}) => Padding(
        padding: landscape
            ? const EdgeInsets.symmetric(horizontal: 12)
            : const EdgeInsets.only(bottom: 24, top: 8),
        child: landscape
            ? Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (!_shutter.isRecording) _modeChips(landscape: true),
                  const SizedBox(height: 16),
                  _shutterButton(),
                  const SizedBox(height: 16),
                  _switchCameraButton(),
                ],
              )
            : Column(
                children: [
                  if (!_shutter.isRecording) _modeChips(landscape: false),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      const SizedBox(width: 48),
                      _shutterButton(),
                      _switchCameraButton(),
                    ],
                  ),
                ],
              ),
      );

  Widget _modeChips({required bool landscape}) => Flex(
        direction: landscape ? Axis.vertical : Axis.horizontal,
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (final m in CaptureMode.values)
            Padding(
              padding: landscape
                  ? const EdgeInsets.symmetric(vertical: 4)
                  : const EdgeInsets.symmetric(horizontal: 4),
              child: GestureDetector(
                onTap: () => _switchMode(m),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: _shutter.mode == m
                        ? Colors.white24
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    m == CaptureMode.photo
                        ? 'camera.photo'.tr()
                        : 'camera.video'.tr(),
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: _shutter.mode == m
                          ? FontWeight.w700
                          : FontWeight.w400,
                    ),
                  ),
                ),
              ),
            ),
        ],
      );

  /// The shutter. It only reports what the finger did — what that means is
  /// decided by [CameraShutter].
  Widget _shutterButton() {
    final laeuft = _shutter.isRecording;
    return GestureDetector(
      onTap: () => unawaited(_perform(_shutter.tap())),
      onLongPressStart: (_) {
        _dragStart();
        unawaited(_perform(_shutter.holdStart()));
      },
      // Dragging out of the shutter zooms — what is measured is the
      // **distance** from the touch-down point, not the direction. Only that
      // way does the same finger movement mean the same thing in portrait and
      // in landscape.
      onLongPressMoveUpdate: (d) => _dragUpdate(d.offsetFromOrigin.distance),
      onLongPressEnd: (_) {
        _dragEnd();
        unawaited(_perform(_shutter.holdEnd()));
      },
      onLongPressCancel: _dragEnd,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 76,
        height: 76,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: laeuft ? Colors.red : Colors.white,
            width: 4,
          ),
        ),
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: laeuft ? 30 : 58,
            height: laeuft ? 30 : 58,
            decoration: BoxDecoration(
              color: laeuft ? Colors.red : Colors.white,
              borderRadius: BorderRadius.circular(laeuft ? 6 : 29),
            ),
          ),
        ),
      ),
    );
  }
}
