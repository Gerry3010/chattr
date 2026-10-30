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
import '../chats/chat_model.dart';
import '../chats/chats_controller.dart';
import '../media/media_attachment.dart';
import '../settings/media_quality_controller.dart';
import '../media/media_repository.dart';
import '../media/widgets/attach_menu.dart' show maxAlbumItems;
import '../media/widgets/media_caption_sheet.dart';
import '../media/widgets/send_progress_dialog.dart';
import '../places/place_parsers.dart';
import '../../screens/chat/components/place_comment_sheet.dart';
import '../messages/messages_controller.dart';
import 'share_text_edit_sheet.dart';
import '../../core/network/network_errors.dart';

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
      'text: ${media.content != null}, '
      'conversation: ${media.conversationIdentifier})',
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

  /// The chat a Direct Share target names, once it is actually loaded.
  ///
  /// Chats arrive asynchronously after auth, and picking a person from the
  /// share sheet COLD-STARTS the app — so the first look regularly finds an
  /// empty list and the shortcut falls back to the picker. Which is the one
  /// thing the shortcut existed to skip; observed on the emulator 2026-08-05,
  /// and it looked exactly like the routing not working at all.
  ///
  /// Bounded on purpose: after ~4s we stop waiting and let the picker open. A
  /// chat that never appears was left or deleted, and no amount of waiting will
  /// produce it — a picker is the right answer there, an empty screen is not.
  Future<Chat?> _resolveTarget(String? conversationId) async {
    if (conversationId == null || conversationId.isEmpty) return null;
    for (var i = 0; i < 20; i++) {
      if (!mounted) return null;
      final match = ref
          .read(chatsControllerProvider)
          .where((c) => c.id == conversationId)
          .firstOrNull;
      if (match != null) return match;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    logger.info(
      'Share target $conversationId not among the loaded chats — '
      'falling back to the picker',
      tag: 'ShareTarget',
    );
    return null;
  }

  Future<void> _handleShare(SharedMedia media) async {
    final attachments = (media.attachments ?? const <SharedAttachment?>[])
        .whereType<SharedAttachment>()
        .toList();
    final sharedText = media.content?.trim();

    // 0. Did the user already name the target? Picking a person from the
    //    system share sheet's Direct Share row (or long-pressing the launcher
    //    icon) sets `conversationIdentifier` to our chat id — see
    //    ShareSuggestionsChannel. Honouring it is what makes that row a
    //    shortcut instead of a slower way into the same picker.
    //    Resolved against the loaded chats, so a stale shortcut — a chat since
    //    left or deleted — falls back to the picker rather than sending
    //    somewhere the user can no longer see.
    final preselected = await _resolveTarget(media.conversationIdentifier);

    if (attachments.isEmpty && (sharedText == null || sharedText.isEmpty)) {
      // A launcher shortcut carries a target but no payload: that is "open
      // this chat", not a share. Without this the picker would appear and then
      // dismiss itself with nothing sent.
      if (preselected != null) _navigateToChat(preselected.id);
      return;
    }

    // 1. Pick one or MORE target chats (multi-send), unless step 0 named one.
    if (!mounted) return; // _resolveTarget may have waited for the chat list
    final chatIds = preselected != null
        ? [preselected.id]
        : await showForwardChatSheetMulti(
            context: context,
            titleKey: 'share_target.choose_chat',
          );
    if (chatIds == null || chatIds.isEmpty || !mounted) return; // dismissed

    final messenger = ScaffoldMessenger.maybeOf(context);

    // 2. Edit step BEFORE sending: media goes through the regular caption
    //    sheet (edit images, reorder, caption prefilled with the shared
    //    text); pure text/URL gets a small prefilled editor so the user can
    //    comment before/after the link. Backing out aborts the share.
    // 1a. A shared marker or calendar entry (#70) becomes its own card rather
    //     than a link/file. No edit step: there is nothing to edit in a pin,
    //     and the picker already established intent. Anything we cannot read
    //     confidently falls through to the ordinary paths below — that, not a
    //     half-parsed card, is the right answer.
    final placeBody = await _sharedPlaceEnvelope(attachments, sharedText);

    List<OutgoingMedia> items = placeBody != null
        ? const []
        : await _sharedToOutgoingMedia(attachments, messenger);
    String? text = (sharedText != null && sharedText.isNotEmpty)
        ? sharedText
        : null;
    // Only set when the user touched the quality switch in the sheet — `null`
    // means "as configured" (see [CaptionSheetResult]).
    MediaQuality? quality;
    var asShot = false;
    if (!mounted) return;
    if (placeBody != null) {
      // The step between picking a place and sending it: preview the card and
      // offer a line to go with it. Backing out here aborts the share, the
      // same as backing out of the media caption step below.
      final withComment = await showPlaceCommentSheet(
        context,
        envelope: placeBody,
      );
      if (withComment == null || !mounted) return;
      text = withComment;
    } else if (items.isNotEmpty) {
      final result = await showMediaCaptionSheet(
        context,
        items: items,
        initialText: text,
      );
      if (result == null || !mounted) return; // backed out
      items = result.items;
      text = result.caption.trim().isEmpty ? null : result.caption.trim();
      quality = result.quality;
      asShot = result.asShot;
    } else if (text != null) {
      text = await showShareTextEditSheet(context, initialText: text);
      if (text == null || !mounted) return; // backed out
    } else {
      return; // nothing shareable
    }

    // 3. Send to every picked chat. messagesControllerProvider is autoDispose
    //    and the target chats are not open — keep each alive for the duration
    //    (same pattern as MessageForwardService). ONE progress dialog spans
    //    the whole loop; cancel aborts the remaining chats.
    final totalOut = items.fold<int>(0, (s, i) => s + i.size);
    final hasVideo =
        items.any((i) => MediaType.fromMime(i.mime) == MediaType.video);
    final showProgress = items.isNotEmpty && totalOut > 3 * 1024 * 1024;
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
          cancelled = true; // aborts at the next chunk/file/chat boundary
          closeDialog();
        },
      );
    }

    var sentChats = 0;
    try {
      for (final (index, chatId) in chatIds.indexed) {
        if (cancelled) break;
        final keepAlive = ref.listenManual(
          messagesControllerProvider(chatId),
          (previous, next) {},
        );
        try {
          final messages =
              ref.read(messagesControllerProvider(chatId).notifier);
          if (items.isNotEmpty) {
            await messages.sendMediaAlbum(
              files: items,
              caption: text,
              quality: quality,
              asShot: asShot,
              // Progress across the whole loop: each chat owns an equal slice.
              onProgress: showProgress
                  ? (p) => progress.value =
                      ((index + p) / chatIds.length).clamp(0.0, 1.0)
                  : null,
              isCancelled: showProgress ? () => cancelled : null,
            );
          } else {
            // Rethrown so a failure is reported, not counted as sent; the
            // failed bubble stays in that chat for a retry (CHAT-66).
            await messages.sendMessage(text!, rethrowFailure: true);
          }
          sentChats++;
        } finally {
          keepAlive.close();
        }
      }

      if (sentChats > 0) {
        messenger?.showSnackBar(
          SnackBar(
            content: Text(
              sentChats == 1
                  ? 'share_target.sent'.tr()
                  : 'share_target.sent_multi'.tr(args: ['$sentChats']),
            ),
          ),
        );
        // Single target: jump into the chat (as before). Multi-send: stay
        // where we are — there is no single obvious destination.
        if (sentChats == 1 && chatIds.length == 1) {
          _navigateToChat(chatIds.first);
        }
      }
    } on MediaSendCancelledException {
      // User aborted via the progress box — no error to surface.
    } catch (e) {
      logger.error('Share send failed', tag: 'ShareTarget', error: e);
      messenger?.showSnackBar(
        SnackBar(content: Text(isNetworkError(e)
          ? 'errors.send_offline'.tr()
          : 'media.send_error'.tr(args: ['$e']))),
      );
    } finally {
      closeDialog();
      progress.dispose();
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

/// A shared pin or calendar entry as an envelope body, or null when the share
/// is something else (#70).
///
/// Reads only what is already in the payload — no lookup, no geocoding, no
/// resolving of short links. Following `maps.app.goo.gl/…` would mean asking
/// Google where the pin is from the sender's device at share time, which is
/// exactly the kind of quiet request this app does not make. Such a link stays
/// an ordinary message with its link preview.
Future<String?> _sharedPlaceEnvelope(
  List<SharedAttachment> attachments,
  String? sharedText,
) async {
  // Already a finished envelope? Then nothing here needs to interpret it.
  final verbatim = verbatimPlaceEnvelope(sharedText);
  if (verbatim != null) return verbatim;

  // A calendar file: exactly one attachment, and it has to read as iCalendar.
  if (attachments.length == 1) {
    final path = attachments.first.path;
    if (path.toLowerCase().endsWith('.ics')) {
      try {
        final file = File(path);
        // Guard the read: a huge or binary "ics" is not one, and this runs on
        // the UI isolate.
        if (await file.length() <= 512 * 1024) {
          final event = parseIcs(await file.readAsString());
          if (event != null) return event.encode();
        }
      } catch (e) {
        logger.info('Shared .ics not readable, sending as a file: $e',
            tag: 'ShareTarget');
      }
    }
  }
  // A map link / geo: URI — only when nothing else rides along, so a photo
  // captioned with a map link stays a photo.
  if (attachments.isEmpty) {
    final pin = parseSharedLocation(sharedText);
    if (pin != null) return pin.encode();
  }
  return null;
}

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
