// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:typed_data';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, visibleForTesting, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../core/logging/logger_service.dart';
import '../../../core/navigation/app_page_route.dart';
import '../../../core/security/security_providers.dart';
import '../../screen_security/screen_security_controller.dart';
import '../media_attachment.dart';
import '../media_repository.dart';
import '../shot_envelope.dart';
import '../video_render_config.dart';
import '../video_source.dart';
import 'fullscreen_image_viewer.dart' show SwipeDownToDismiss;
import 'media_message_view.dart' show decryptedMediaProvider;

/// Shows a shot exactly once.
///
/// The sequence is deliberately in this order:
///
///   1. **Ask.** A mistap would otherwise be final, and this is also where the
///      honest sentence about screenshots stands — the place where somebody
///      actually reads it.
///   2. **Load.** Only once the content is really there does the shot count as
///      opened. If loading fails, everything stays as it was; otherwise a
///      network error would consume the shot.
///   3. **Show**, with screen capture blocked meanwhile (only Android can do
///      that — see [ScreenSecurityController]).
///   4. **Burn**, as soon as there is something to see — via [onViewed].
///
/// Returns `true` when the shot really was visible.
///
/// **Why the burn hangs on the opening and not on the closing.** Between "seen"
/// and "closed" lie arbitrarily many ways out that carry no return value: the
/// back button (that is exactly where it came out on the Galaxy), the swipe
/// gesture — and the one no redirect catches: killing the app while the shot is
/// open. Whoever hangs the burn on closing has to catch every one of those paths
/// and loses the whole promise at the first one they miss. Hung on the opening
/// there is only ONE moment, and it is precisely the one in which the content is
/// on screen.
///
/// [own] inverts this: the **sender** may look at their own shot for as long as
/// the bubble stands (Gerry, 2026-08-28) — they should be able to check what they
/// sent. For them there is therefore neither a prompt nor a burn: it is their own
/// content, and the warning "it is gone afterwards" would simply be false. It is
/// gone for them too, but via the 24-hour clock, not via the look.
Future<bool> showShot(
  BuildContext context,
  WidgetRef ref,
  ShotEnvelope shot, {
  bool own = false,
  FutureOr<void> Function()? onViewed,
}) async {
  final attachment = shot.attachment;
  if (attachment == null) return false;

  // The prompt comes ONCE PER KIND (Gerry, 2026-08-28): once for photos, once
  // for videos. It explains something one has understood after the first time —
  // after that it is just one more tap between the user and what they want to
  // see. Per kind, because a video behaves differently from a photo (it plays
  // through once), and because the first video shot is therefore a first moment
  // of its own.
  final storage = ref.read(secureStorageProvider);
  final seen = own ? const <String>{} : await _seen(storage);
  if (!own && !seen.contains(shot.kind.name)) {
    // There was an await between reading from storage and here.
    if (!context.mounted) return false;
    final bestaetigt = await _confirm(context);
    if (bestaetigt != true || !context.mounted) return false;
    // Only remember AFTER the yes. Whoever cancels has not decided — and gets
    // the question again next time.
    await _rememberSeen(storage, seen, shot.kind);
  }
  if (!context.mounted) return false;

  final security = ref.read(screenSecurityProvider.notifier);
  return security.secureWhile(() async {
    if (!context.mounted) return false;
    final gezeigt = await Navigator.of(context).push<bool>(
      appPageRoute<bool>(
        fullscreenDialog: true,
        builder: (_) => ShotScreen(
          attachment: attachment,
          kind: shot.kind,
          onViewed: onViewed,
        ),
      ),
    );
    return gezeigt ?? false;
  });
}

/// On Android the viewer blocks screenshots; everywhere else the app cannot —
/// and says so, instead of claiming protection that does not exist.
bool get _screenshotsBlockable =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// Which kinds of shot the user has already answered the prompt for.
const String _warningSeenKey = 'shot_open_warning_seen_v1';

Future<Set<String>> _seen(FlutterSecureStorage storage) async {
  try {
    final raw = await storage.read(key: _warningSeenKey) ?? '';
    return raw.split(',').where((e) => e.isNotEmpty).toSet();
  } catch (_) {
    // Unreadable: then the question simply comes again. That is the harmless
    // direction.
    return <String>{};
  }
}

Future<void> _rememberSeen(
  FlutterSecureStorage storage,
  Set<String> seen,
  MediaType kind,
) async {
  try {
    await storage.write(
      key: _warningSeenKey,
      value: ({...seen, kind.name}).join(','),
    );
  } catch (_) {
    // Not storable only means: the question comes again.
  }
}

Future<bool?> _confirm(BuildContext context) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('shots.confirm_open_title'.tr()),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('shots.confirm_open_body'.tr()),
          const SizedBox(height: 12),
          Text(
            _screenshotsBlockable
                ? 'shots.screenshot_note_android'.tr()
                : 'shots.screenshot_note'.tr(),
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(ctx).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text('common.cancel'.tr()),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text('shots.confirm_open_action'.tr()),
        ),
      ],
    ),
  );
}

/// The full-screen viewer. Public only so a test can build it without a network
/// and without a device — precisely the guarantee that broke on the Galaxy (the
/// shot survived the back button) cannot be pinned down anywhere else. The way
/// in stays [showShot].
@visibleForTesting
class ShotScreen extends ConsumerStatefulWidget {
  const ShotScreen({
    super.key,
    required this.attachment,
    required this.kind,
    this.onViewed,
  });

  final MediaAttachment attachment;
  final MediaType kind;

  /// Called EXACTLY ONCE, as soon as the content is visible.
  final FutureOr<void> Function()? onViewed;

  @override
  ConsumerState<ShotScreen> createState() => ShotScreenState();
}

@visibleForTesting
class ShotScreenState extends ConsumerState<ShotScreen> {
  Uint8List? _bytes;
  Player? _player;
  VideoController? _video;
  VideoSource? _source;
  Object? _error;

  /// Only true once there really was something to see. Only then is anything
  /// burned.
  bool _gezeigt = false;

  /// For an image: while zoomed in, the drag belongs to the image and not to
  /// the swipe gesture — otherwise panning would drag the shot away.
  final TransformationController _zoom = TransformationController();
  bool _zoomedIn = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      if (widget.kind == MediaType.video) {
        await _loadVideo();
      } else {
        final bytes =
            await ref.read(decryptedMediaProvider(widget.attachment).future);
        if (!mounted) return;
        setState(() => _bytes = bytes);
        _markSeenNow();
      }
    } catch (e) {
      logger.warning('Shot konnte nicht geladen werden: $e', tag: 'Shot');
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _loadVideo() async {
    final att = widget.attachment;
    final repo = ref.read(mediaRepositoryProvider);
    final svc = ref.read(messageEncryptionServiceProvider);
    final source = att.isChunked
        // A shot streams too (1.27) — and that fits particularly well here:
        // this way not even a temporary decrypted file of something that is
        // about to disappear comes into being on disk.
        ? await VideoSource.streaming(att, repo, svc)
        : await VideoSource.create(
            await ref.read(decryptedMediaProvider(att).future),
            att.name,
            att.mime,
          );
    if (!mounted) {
      await source.dispose();
      return;
    }
    final player = Player();
    final controller = VideoController(
      player,
      configuration: VideoControllerConfiguration(
        enableHardwareAcceleration: !useSoftwareVideoRendering,
      ),
    );
    await player.open(Media(source.uri));
    if (!mounted) {
      await player.dispose();
      await source.dispose();
      return;
    }
    setState(() {
      _source = source;
      _player = player;
      _video = controller;
    });
    _markSeenNow();
  }

  /// The shot is on screen — from here it is spent, however the viewer ends.
  ///
  /// The burn clears away the local copy underneath the still-open viewer; that
  /// does not disturb it: the image data lies in memory here, and the video
  /// stream already holds its own media key ([DecryptedMediaServer]). What
  /// disappears is the way BACK in.
  void _markSeenNow() {
    if (_gezeigt) return;
    _gezeigt = true;
    final report = widget.onViewed;
    if (report == null) return;
    () async {
      try {
        await report();
      } catch (e) {
        logger.warning('Shot konnte nicht verbraucht werden: $e', tag: 'Shot');
      }
    }();
  }

  @override
  void dispose() {
    // No PiP, no handover: a shot does not leave this screen.
    _player?.dispose();
    _source?.dispose();
    _zoom.dispose();
    super.dispose();
  }

  /// The ONE exit. Every way out — close button, back button, swipe gesture —
  /// runs through here and carries the same return value.
  void _close() {
    if (!mounted) return;
    Navigator.of(context).pop(_gezeigt);
  }

  @override
  Widget build(BuildContext context) {
    // `canPop: false` is not a bolt here but a redirect: a system pop (back
    // button, edge swipe) would otherwise end the page WITHOUT a return value —
    // the caller would get `null`, read it as "nothing seen", and the shot
    // would stay unopened although it had been open. That is exactly how it
    // could be viewed any number of times on the Galaxy (Gerry, 2026-08-28).
    // With the redirect, [_close] always decides what goes back.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Scaffold(
        // Black stays black. The gallery viewer sits on a TRANSPARENT route and
        // therefore lets the chat show through while swiping; this one is
        // opaque (`appPageRoute`), so a transparent scaffold would paint into
        // nothing. And with a shot that would be the wrong direction anyway:
        // while it slides down, the chat behind it should not appear.
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          elevation: 0,
          leading: IconButton(
            tooltip: 'shots.close'.tr(),
            icon: const Icon(Icons.close),
            onPressed: _close,
          ),
          title: Text('shots.badge'.tr()),
        ),
        body: SwipeDownToDismiss(
          // Swiping down closes — and closing here means open-and-consume,
          // exactly like the close button (Gerry).
          enabled: !_zoomedIn,
          onDismiss: _close,
          child: Center(child: _content()),
        ),
      ),
    );
  }

  Widget _content() {
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'shots.load_failed'.tr(),
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white70),
        ),
      );
    }
    if (_video != null) {
      return Video(controller: _video!, controls: AdaptiveVideoControls);
    }
    if (_bytes != null) {
      return InteractiveViewer(
        transformationController: _zoom,
        minScale: 1,
        maxScale: 4,
        onInteractionUpdate: (_) {
          final zoomedIn = _zoom.value.getMaxScaleOnAxis() > 1.01;
          if (zoomedIn != _zoomedIn) setState(() => _zoomedIn = zoomedIn);
        },
        child: Image.memory(_bytes!, fit: BoxFit.contain),
      );
    }
    return const CircularProgressIndicator(strokeWidth: 2);
  }
}
