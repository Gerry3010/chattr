// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:io' show File, Platform;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_handler/share_handler.dart';

import '../../core/logging/logger_service.dart';
import '../../core/navigation/navigation_provider.dart';
import '../../screens/chat/components/forward_chat_sheet.dart';
import '../auth/auth_controller.dart';
import '../app_lock/app_lock_controller.dart';
import '../chats/chats_controller.dart';
import '../media/media_attachment.dart';
import '../media/media_repository.dart';
import '../media/widgets/attach_menu.dart' show maxAlbumItems;
import '../media/widgets/send_progress_dialog.dart';
import '../messages/messages_controller.dart';

/// Receives content shared from other apps (Android `ACTION_SEND[_MULTIPLE]`
/// via share_handler; iOS needs the share extension — Mac-Claude scope) and
/// routes it through the chat picker into the regular send pipeline.
///
/// Mounted once inside the app's home subtree so it has a navigator-capable
/// context for the picker sheet. Payloads arriving before auth is restored or
/// while the app is locked are queued and processed once both clear.
class ShareTargetListener extends ConsumerStatefulWidget {
  final Widget child;

  const ShareTargetListener({super.key, required this.child});

  @override
  ConsumerState<ShareTargetListener> createState() =>
      _ShareTargetListenerState();
}

class _ShareTargetListenerState extends ConsumerState<ShareTargetListener> {
  StreamSubscription<SharedMedia>? _sub;
  final List<SharedMedia> _queue = [];
  bool _processing = false;

  static bool get _supported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  @override
  void initState() {
    super.initState();
    if (!_supported) return;
    final handler = ShareHandlerPlatform.instance;
    // Cold start: the intent that launched the app.
    handler.getInitialSharedMedia().then((media) {
      if (media != null) _enqueue(media);
    }).catchError((Object e) {
      logger.warning('getInitialSharedMedia failed: $e', tag: 'ShareTarget');
    });
    // Warm: shares arriving while the app is alive.
    _sub = handler.sharedMediaStream.listen(_enqueue, onError: (Object e) {
      logger.warning('sharedMediaStream error: $e', tag: 'ShareTarget');
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _enqueue(SharedMedia media) {
    logger.info(
      'Share received (${media.attachments?.length ?? 0} attachments, '
      'text: ${media.content != null})',
      tag: 'ShareTarget',
    );
    _queue.add(media);
    _drainQueue();
  }

  Future<void> _drainQueue() async {
    if (_processing) return;
    _processing = true;
    try {
      while (_queue.isNotEmpty) {
        final ready = await _waitUntilReady();
        if (!ready || !mounted) return;
        final media = _queue.removeAt(0);
        await _handleShare(media);
      }
    } finally {
      _processing = false;
    }
  }

  /// Waits until a session exists and the app lock is open (the picker must
  /// never appear above the lock screen). Gives up after ~60s.
  Future<bool> _waitUntilReady() async {
    for (var i = 0; i < 120; i++) {
      if (!mounted) return false;
      final authed = ref.read(authControllerProvider) != null;
      final locked = ref.read(appLockControllerProvider).locked;
      if (authed && !locked) return true;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    logger.warning('Share dropped: auth/unlock never became ready',
        tag: 'ShareTarget');
    return false;
  }

  Future<void> _handleShare(SharedMedia media) async {
    final chatId = await showForwardChatSheet(
      context: context,
      titleKey: 'share_target.choose_chat',
    );
    if (chatId == null || !mounted) return; // dismissed

    final messenger = ScaffoldMessenger.maybeOf(context);
    // messagesControllerProvider is autoDispose and the target chat is not
    // open while the picker is up — keep it alive for the duration of the
    // send (same pattern as MessageForwardService).
    final keepAlive = ref.listenManual(
      messagesControllerProvider(chatId),
      (previous, next) {},
    );
    final messages = ref.read(messagesControllerProvider(chatId).notifier);
    var sent = 0;

    try {
      final attachments = (media.attachments ?? const <SharedAttachment?>[])
          .whereType<SharedAttachment>()
          .toList();
      final text = media.content?.trim();

      // Group ALL shared files into ONE album (#109) instead of N separate
      // messages; the shared text becomes the album caption (not an extra
      // message). Text-only shares still go through sendMessage.
      final items = await _sharedToOutgoingMedia(attachments, messenger);
      if (items.isNotEmpty) {
        // Show the same determinate progress box as the in-app attach flow —
        // large shared videos take a while to encrypt/chunk, and without this
        // the share looks like it did nothing until the send finishes.
        final totalOut = items.fold<int>(0, (s, i) => s + i.size);
        final hasVideo =
            items.any((i) => MediaType.fromMime(i.mime) == MediaType.video);
        final showProgress = totalOut > 3 * 1024 * 1024;
        final progress = ValueNotifier<double>(0);
        var cancelled = false;
        var dialogOpen = false;
        void closeDialog() {
          if (dialogOpen && mounted) {
            dialogOpen = false;
            Navigator.of(context, rootNavigator: true).pop();
          }
        }

        if (showProgress && mounted) {
          dialogOpen = true;
          showSendProgressDialog(
            context,
            progress,
            isVideo: hasVideo,
            onCancel: () {
              cancelled = true; // aborts at the next chunk/file boundary
              closeDialog();
            },
          );
        }
        try {
          await messages.sendMediaAlbum(
            files: items,
            caption: (text != null && text.isNotEmpty) ? text : null,
            onProgress: showProgress ? (p) => progress.value = p : null,
            isCancelled: showProgress ? () => cancelled : null,
          );
          sent = items.length;
        } on MediaSendCancelledException {
          // User aborted via the progress box — no error to surface.
        } finally {
          closeDialog();
          progress.dispose();
        }
      } else if (text != null && text.isNotEmpty) {
        await messages.sendMessage(text);
        sent = 1;
      }

      if (sent > 0) {
        messenger?.showSnackBar(
          SnackBar(content: Text('share_target.sent'.tr())),
        );
        _navigateToChat(chatId);
      }
    } catch (e) {
      logger.error('Share send failed', tag: 'ShareTarget', error: e);
      messenger?.showSnackBar(
        SnackBar(content: Text('media.send_error'.tr(args: ['$e']))),
      );
    } finally {
      keepAlive.close();
    }
  }

  void _navigateToChat(String chatId) {
    final chat = ref
        .read(chatsControllerProvider)
        .where((c) => c.id == chatId)
        .firstOrNull;
    if (chat == null || !mounted) return;
    ref.read(navigationServiceProvider).navigateToChat(chat);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Converts incoming shared attachments into send-ready [OutgoingMedia],
/// mirroring attach_menu's `_filesToOutgoingMedia`: any large path-backed file
/// keeps its path for chunked upload (no full read into RAM — videos and big
/// documents/archives alike), oversized pathless files are skipped with a
/// warning, and the batch is capped at [maxAlbumItems].
Future<List<OutgoingMedia>> _sharedToOutgoingMedia(
  List<SharedAttachment> attachments,
  ScaffoldMessengerState? messenger,
) async {
  final items = <OutgoingMedia>[];
  for (final a in attachments) {
    if (items.length >= maxAlbumItems) {
      messenger?.showSnackBar(SnackBar(
        content: Text('media.too_many'.tr(args: ['$maxAlbumItems'])),
      ));
      break;
    }
    final name = a.path.split('/').last;
    final mime = mimeForExtension(name.split('.').last);
    final size = await File(a.path).length();
    // Any large shared file → CHUNKED (keep the path, stream it later) — videos
    // and big documents/archives alike, never the whole file in RAM.
    if (!kIsWeb && size > MediaRepository.chunkThresholdBytes) {
      items.add(
        OutgoingMedia.file(a.path, size: size, fileName: name, mime: mime),
      );
      continue;
    }
    // Small files → in-memory bytes; the RAM ceiling only bites web/pathless now.
    if (size > MediaRepository.maxInMemoryBytes) {
      messenger?.showSnackBar(SnackBar(
        content:
            Text('media.too_large'.tr(args: [MediaRepository.maxInMemoryLabel])),
      ));
      continue;
    }
    final bytes = await File(a.path).readAsBytes();
    items.add(OutgoingMedia.bytes(bytes, fileName: name, mime: mime));
  }
  return items;
}
