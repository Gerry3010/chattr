// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:chatview/chatview.dart' as chatview;
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../core/security/keys_not_ready_exception.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/theme_controller.dart';
import '../../../core/utils/app_time.dart';

import '../../../features/chat_view/chat_view_controller.dart';
import '../../../features/media/clipboard_paste.dart';
import '../../../features/media/composer_paste_menu.dart';
import '../../../features/media/media_attachment.dart';
import '../../../features/media/widgets/attach_menu.dart';
import '../../../features/media/widgets/audio_recorder_button.dart';
import '../../../features/media/widgets/media_album_view.dart';
import '../../../features/media/widgets/media_message_view.dart';
import '../../../features/messages/drafts_repository.dart';
import '../../../features/messages/message_forward_service.dart';
import '../../../features/messages/message_model.dart' show Message, systemId;
import '../../../features/messages/messages_controller.dart';
import '../../../features/settings/markdown_bar_controller.dart';
import '../../../features/messages/message_links.dart';
import '../../../features/messages/message_ordering.dart';
import '../../../features/messages/message_markdown.dart';
import '../../../features/read_receipts/read_receipts_controller.dart';
import 'chat_view_app_bar.dart';
import 'chat_view_textfield.dart';
import 'scroll_to_bottom_button.dart';
import 'forward_chat_sheet.dart';
import 'link_message_bubble.dart';
import 'markdown_message_bubble.dart';
import 'message_actions_sheet.dart';
import 'timestamp_info.dart';

/// The main body of the ChatViewScreen, containing the message list and text field.
///
/// It configures the `chatview.ChatView` widget with appropriate themes,
/// behaviors, and callbacks, all managed by the [ChatViewController].
class ChatViewBody extends ConsumerStatefulWidget {
  final String chatId;

  const ChatViewBody({
    super.key,
    required this.chatId,
  });

  @override
  ConsumerState<ChatViewBody> createState() => _ChatViewBodyState();
}

class _ChatViewBodyState extends ConsumerState<ChatViewBody> {
  final GlobalKey<State<chatview.ChatView>> _chatViewKey = GlobalKey();
  final GlobalKey<ChatViewTextFieldState> _textFieldKey = GlobalKey();

  Timer? _draftDebounce;
  String? _pendingDraft;
  late final DraftsRepository _draftsRepo;

  @override
  void initState() {
    super.initState();
    _draftsRepo = ref.read(draftsRepositoryProvider);
    _restoreDraft();
  }

  /// Restores a saved draft into the composer once it is mounted.
  Future<void> _restoreDraft() async {
    final draft = await _draftsRepo.getDraft(widget.chatId);
    if (draft == null || !mounted) return;
    final fieldState = _textFieldKey.currentState;
    if (fieldState != null) {
      fieldState.seedDraft(draft);
    } else {
      // Composer not built yet (draft loads faster than the first frame).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _textFieldKey.currentState?.seedDraft(draft);
      });
    }
  }

  /// Debounced persistence of composer text. Sending clears the field, which
  /// arrives here as '' and deletes the draft — no explicit clear-on-send.
  void _onDraftChanged(String text) {
    _pendingDraft = text;
    _draftDebounce?.cancel();
    _draftDebounce = Timer(const Duration(milliseconds: 500), _flushDraft);
  }

  void _flushDraft() {
    final text = _pendingDraft;
    if (text == null) return;
    _pendingDraft = null;
    _draftsRepo.saveDraft(widget.chatId, text);
  }

  @override
  void dispose() {
    _draftDebounce?.cancel();
    _flushDraft();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(chatViewControllerProvider(widget.chatId));
    final controller = ref.read(chatViewControllerProvider(widget.chatId).notifier);

    final canSend = state.usernames.length > 1 && !state.isNotMember;
    final viewState = state.messages.isNotEmpty
        ? chatview.ChatViewState.hasMessages
        : chatview.ChatViewState.noData;

    // Inline emojis inside a text bubble render at ~1.125× the body text size
    // (fork p13 `ChatBubble.emojiSize`) — a touch above the body text (14 → ~16)
    // so bare/inline emojis don't read as too small, without the oversized look
    // of the earlier 1.4/1.25. Derived from the theme's body size so it scales
    // with each theme (the bubble textStyle sets no fontSize, so the body
    // inherits bodyMedium). Emoji-ONLY messages are unaffected — they take the
    // package's separate big-emoji path (default 30px).
    final emojiInlineSize =
        (Theme.of(context).textTheme.bodyMedium?.fontSize ?? 14) * 1.125;

    final featureActiveConfig = chatview.FeatureActiveConfig(
      enableTextField: !state.isPending && !state.isNotMember,
      enableSwipeToReply: !state.isPending && !state.isNotMember,
      // Long-press opens our unified message-actions sheet via the fork's clean
      // ChatBubbleConfiguration.onLongPress (below) — no reaction popup and no
      // reply-snackbar hijack needed.
      enableReactionPopup: false,
      enableReplySnackBar: false,
      // Double-tap is repurposed as the message-actions menu too, so disable
      // the built-in double-tap-to-like.
      enableDoubleTapToLike: false,
      enablePagination: true,
      // Timestamps live INSIDE the bubbles (WhatsApp-style). Swipe-to-see-time
      // is off for good: every bubble is wrapped in SwipeToReply's own
      // horizontal-drag detector, which wins the gesture arena — the
      // list-level time-reveal could only ever fire on empty background, so
      // the times were effectively unreachable (and on web it fought the
      // edge-swipe-back gesture on top).
      showTimeInChatBubble: true,
      enableSwipeToSeeTime: false,
      // Show other users' self-chosen profile pictures next to their bubbles in
      // ALL chats (1:1 and groups) — the picture is user-chosen, so there's no
      // privacy reason to hide it. This was previously OFF because chatview
      // collapses a picture-less user's avatar to 0px (the default-avatar
      // fallback was unreachable when profilePhoto is null), which made the last
      // grouped bubble jump to the far left. The fork p12 patch fixes that at the
      // source: ProfileImageWidget now renders a deterministic initials circle
      // when there is no image, so every incoming bubble keeps a stable avatar
      // slot and groups still read as one block.
      enableOtherUserProfileAvatar: true,
      // chatview's own scroll-to-bottom button stays OFF: with our custom
      // sendMessageBuilder its taps fall through to the message underneath. We
      // render our own [ChatScrollToBottomButton] over the chat instead.
      enableScrollToBottomButton: false,
    );

    // Theme wallpaper shown behind the messages, if the theme has one.
    final appTheme = ref.watch(themeControllerProvider);
    final wallpaper = appTheme.wallpaper;
    // Forest keeps its wallpaper at natural exposure, so its bubbles get a
    // subtle outline to separate them from the bright photo (Forest-only — the
    // other themes' bubbles stay borderless).
    final isForest = appTheme == AppTheme.forest;
    final bubbleScheme = Theme.of(context).colorScheme;
    final Border? outgoingBubbleBorder = isForest
        ? Border.all(
            color: bubbleScheme.onPrimaryContainer.withValues(alpha: 0.22),
            width: 1,
          )
        : null;
    final Border? incomingBubbleBorder = isForest
        ? Border.all(
            color: bubbleScheme.onSurface.withValues(alpha: 0.16),
            width: 1,
          )
        : null;
    final chatBackgroundConfiguration = chatview.ChatBackgroundConfiguration(
      backgroundColor: wallpaper != null
          ? Colors.transparent
          : Theme.of(context).colorScheme.surfaceContainerLowest,
      // Render strictly by `createdAt` instead of trusting chatview's raw
      // insertion order. Our controller mirrors the (correctly ordered)
      // Riverpod message list into chatview via `ChatController.addMessage`,
      // which always APPENDS to the tail — so a scrolled-up older page (and any
      // out-of-order realtime arrival) landed among the newest messages and the
      // conversation read jumbled. With `sortEnable` the list widget sorts every
      // render, making insertion order irrelevant. `groupedListOrder` stays at
      // its default `asc`, so this comparator's output order IS the final order.
      sortEnable: true,
      // Stable total order: newest→oldest by time, message id as deterministic
      // tiebreak (see message_ordering.dart). `created_at` alone isn't unique
      // (ms/us collisions, mixed client-clock vs server-NOW() timestamps), and
      // Dart's List.sort isn't stable — the id tiebreak removes the residual
      // jitter without needing a chatview fork patch.
      messageSorter: (a, b) => compareMessagesNewestFirst(
        a.createdAt,
        a.id,
        b.createdAt,
        b.id,
      ),
      // Dragging the message list hides the keyboard (standard messenger
      // behavior) — a fork addition that dismisses only on touch drag, not on
      // mouse-wheel/programmatic scroll.
      scrollViewKeyboardDismissBehavior:
          ScrollViewKeyboardDismissBehavior.onDrag,
    );

    final markdownBarEnabled = ref.watch(markdownBarEnabledProvider);
    final sendMessageConfiguration = chatview.SendMessageConfiguration(
      // We supply our own voice recorder via trailingActions (AudioRecorderButton).
      // chatview's ChatUITextField *also* renders a built-in mic when
      // allowRecordingVoice is true (its default) — that produced two mic icons.
      // Disable the package one so only our recorder shows.
      allowRecordingVoice: false,
      // Ctrl/Cmd+V in the composer (fork feature): send a pasted image/file
      // through the E2E media pipeline. Plain text is left to the field's
      // native paste. Platform-gated in the fork (desktop/web on, mobile off);
      // mobile pastes via the attach sheet's paste tile instead.
      onPaste: canSend
          ? (_) => pasteClipboardMedia(
                context: context,
                onSend: controller.sendMedia,
              )
          : null,
      // Composer long-press menu: add a media "Einfügen" entry when the
      // clipboard holds an image/file (fork p9 passthrough). This is the mobile
      // paste path — iOS has no Cmd+V and its native toolbar only pastes text,
      // so a clipboard image otherwise looks un-pasteable (#92).
      composerContextMenuBuilder: canSend
          ? (menuContext, editableState) => buildComposerContextMenu(
                menuContext,
                editableState,
                onPasteMedia: () => pasteClipboardMedia(
                  context: context,
                  onSend: controller.sendMedia,
                ),
                markdownBarEnabled: markdownBarEnabled,
                onToggleMarkdownBar: () =>
                    ref.read(markdownBarEnabledProvider.notifier).toggle(),
              )
          : null,
      textFieldBackgroundColor: Theme.of(context).colorScheme.surface,
      defaultSendButtonColor: Theme.of(context).colorScheme.primary,
      // replyMessageColor is the quoted TEXT color (not a background) — it
      // previously got surfaceContainerHighest, which is near-invisible on the
      // dialog surface in dark mode.
      replyMessageColor: Theme.of(context).colorScheme.onSurfaceVariant,
      replyDialogColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      replyTitleColor: Theme.of(context).colorScheme.primary,
      closeIconColor: Theme.of(context).colorScheme.onSurfaceVariant,
      textFieldConfig: chatview.TextFieldConfiguration(
        enabled: canSend,
        hintText: 'chat_view.type_message'.tr(),
        textStyle: TextStyle(color: Theme.of(context).colorScheme.onSurface),
        // Left: a single attach button opening the WhatsApp-style share sheet
        // (replaces chatview's default camera/gallery icons).
        leadingActions: (ctx, ctrl) => canSend
            ? [
                IconButton(
                  icon: const Icon(Icons.attach_file),
                  tooltip: 'media.attach'.tr(),
                  onPressed: () {
                    // Prefill the caption sheet with whatever is already typed
                    // in the composer (#6). The composer is cleared ONLY once
                    // the media actually sends (onSend runs) — a cancelled
                    // caption sheet keeps the typed text.
                    final typed = _textFieldKey.currentState?.text ?? '';
                    showAttachSheet(
                      context: context,
                      initialText: typed.trim().isEmpty ? null : typed,
                      onSend: ({
                        required items,
                        caption,
                        onProgress,
                        isCancelled,
                      }) async {
                        await controller.sendMedia(
                          items: items,
                          caption: caption,
                          onProgress: onProgress,
                          isCancelled: isCancelled,
                        );
                        _textFieldKey.currentState?.clearText();
                      },
                    );
                  },
                ),
              ]
            : const [],
        // Right: only the voice recorder.
        trailingActions: (ctx, ctrl) => [
          AudioRecorderButton(
            onSend: controller.sendMedia,
            enabled: canSend,
          ),
        ],
        onMessageTyping: (status) {
          controller.setTyping(status == chatview.TypeWriterStatus.typing);
        },
        compositionThresholdTime: const Duration(seconds: 2),
      ),
    );

    // Favorited (#4) message ids, watched so the star badge appears/clears
    // reactively when a message is (un)favorited.
    final favoriteMessageIds = ref
        .watch(messagesControllerProvider(widget.chatId))
        .whereType<Message>()
        .where((m) => m.isFavorite)
        .map((m) => m.id)
        .toSet();

    final messageConfiguration = chatview.MessageConfiguration(
      // Media and link messages are custom-rendered but fully reactable.
      showReactionsOnCustomMessages: true,
      customMessageBuilder: _customMessageBuilder(context, state),
      // Star badge on favorited bubbles (fork p17, works across all types).
      isMessageStarred: (chatview.Message m) =>
          favoriteMessageIds.contains(m.id),
      messageReactionConfig: chatview.MessageReactionConfiguration(
        backgroundColor: Theme.of(context).colorScheme.surface,
        borderColor: Theme.of(context).colorScheme.outline,
        // Fully-round stadium pill: the package default (circular(16)) isn't
        // round enough on a taller multi-emoji pill, which read as a rounded
        // rectangle. A large radius + snug padding gives a clean pill.
        borderRadius: BorderRadius.circular(999),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        // The "who reacted" sheet defaults to white cards + light-gray
        // text — unreadable in dark mode. Style it from the theme.
        reactionsBottomSheetConfig: chatview.ReactionsBottomSheetConfiguration(
          backgroundColor: Theme.of(context).colorScheme.surface,
          reactionWidgetDecoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: const BorderRadius.all(Radius.circular(10)),
          ),
          reactedUserTextStyle: TextStyle(
            color: Theme.of(context).colorScheme.onSurface,
            fontSize: 14,
          ),
          reactionSize: 18,
        ),
      ),
    );

    final chatView = chatview.ChatView(
      key: _chatViewKey,
      chatController: controller.chatController,
      // Jump-to-message + pulse from favorites / global search (fork p18).
      highlightMessageNotifier: controller.highlightNotifier,
      onSendTap: canSend
          ? (message, replyMessage, messageType) async {
              final messenger = ScaffoldMessenger.of(context);
              try {
                await controller.sendMessage(message,
                    replyMessage: replyMessage);
              } on KeysNotReadyException {
                // Peer hasn't registered its chat key yet (just-added/scanned).
                // The send already retried; tell the user to try again shortly
                // instead of surfacing a raw error (#116).
                messenger.showSnackBar(
                  SnackBar(content: Text('chat_view.keys_not_ready'.tr())),
                );
              }
            }
          : null,
      sendMessageBuilder: (replyMessage) =>
          ChatViewTextField(
        key: _textFieldKey,
        // chatview's swipe-to-reply sets the reply on ITS SendMessageWidget
        // state and re-invokes this builder with it — forward it so our text
        // field can adopt it (it was silently discarded before, which made
        // swipe-to-reply a no-op).
        pendingReply: replyMessage ?? const chatview.ReplyMessage(),
        sendMessageConfig: sendMessageConfiguration,
        onSendTap: _chatViewKey.currentState?.widget.onSendTap,
        onDraftChanged: _onDraftChanged,
      ),
      isLastPage: () => !state.hasMoreMessages,
      loadMoreData: (direction, message) async {
        if (direction == chatview.ChatPaginationDirection.previous) {
          await controller.loadMoreMessages();
        }
      },
      featureActiveConfig: featureActiveConfig,
      chatViewState: viewState,
      chatViewStateConfig: chatview.ChatViewStateConfiguration(
        loadingWidgetConfig: chatview.ChatViewStateWidgetConfiguration(
          loadingIndicatorColor: Theme.of(context).primaryColor,
        ),
        // Localize the empty state (was the package default "No message" /
        // "Reload" English text); hide the non-functional reload button.
        noMessageWidgetConfig: chatview.ChatViewStateWidgetConfiguration(
          title: 'chat_view.no_messages'.tr(),
          showDefaultReloadButton: false,
        ),
        onReloadButtonTap: () {},
      ),
      typeIndicatorConfig: chatview.TypeIndicatorConfiguration(
        flashingCircleBrightColor: Theme.of(context).colorScheme.primary,
        flashingCircleDarkColor:
            Theme.of(context).colorScheme.primary.withValues(alpha: 0.5),
      ),
      appBar: ChatViewAppBar(chatId: widget.chatId),
      chatBackgroundConfig: chatBackgroundConfiguration,
      sendMessageConfig: sendMessageConfiguration,
      chatBubbleConfig: chatview.ChatBubbleConfiguration(
        // Link messages render via LinkMessageBubble (compact favicon+title
        // row). Keep the package's AnyLinkPreview card off everywhere as a
        // safety net — if its URL regex catches something ours misses, the
        // card would come back as a big empty white block.
        disableLinkPreview: true,
        onDoubleTap: (message) => _showMessageActions(controller, state, message),
        onLongPress: (message) => _showMessageActions(controller, state, message),
        // Slide-to-Timestamp (#107b): an opposite-direction swipe peeks the
        // delivered/read time inline; in groups a hard swipe opens the
        // per-recipient info sheet. Read times honour the reciprocal
        // read-receipt privacy setting.
        timestampRevealBuilder: (message) {
          final m = _chattrMessage(state, message.id);
          if (m == null) return null;
          return buildTimestampRevealChip(
            context: context,
            message: m,
            currentUserId: state.currentUserId,
            showReadReceipts: ref.read(sendReadReceiptsProvider),
          );
        },
        onSwipeToTimestamp: (state.chat?.isGroup ?? false)
            ? (message) => _openTimestampInfo(state, message)
            : null,
        outgoingChatBubbleConfig: chatview.ChatBubble(
          color: Theme.of(context).colorScheme.primaryContainer,
          border: outgoingBubbleBorder,
          // Less round than the package defaults (30 short / 18 long → short
          // bubbles look near-pill). Fork p15 keeps the message-grouping corner
          // chaining while letting us dial both radii. Tune these two values.
          shortMessageBorderRadius: 16,
          longMessageBorderRadius: 16,
          textStyle: TextStyle(
            color: Theme.of(context).colorScheme.onPrimaryContainer,
          ),
          // Inline emojis render larger than the body text (fork p13) — at the
          // body size they read as too small. ~1.4× body (see emojiInlineSize).
          emojiSize: emojiInlineSize,
          // The in-bubble timestamp defaults to a hardcoded Colors.white70 /
          // Colors.black54 in the package — the incoming black54 is nearly
          // invisible on the dark bubble in dark mode. Drive it from the theme.
          messageTimeTextStyle: TextStyle(
            color: Theme.of(context)
                .colorScheme
                .onPrimaryContainer
                .withValues(alpha: 0.7),
          ),
          // Persistent WhatsApp-style status ticks on every own message.
          // chatview's default receipt is only a transient send animation
          // that removes itself after the message is sent — delivery/read
          // state was never visible with it.
          receiptsWidgetConfig: chatview.ReceiptsWidgetConfig(
            showReceiptsIn: chatview.ShowReceiptsIn.all,
            receiptsBuilder: _buildReceipt,
            // The package default renders hardcoded English
            // ("Seen now" / "Seen 5 m ago") — localize it.
            lastSeenAgoBuilder: _buildLastSeen,
          ),
          // Without an explicit linkStyle the URL TextSpan has no color at all
          // and paints framework-default black — invisible on dark bubbles.
          linkPreviewConfig: chatview.LinkPreviewConfiguration(
            linkStyle: TextStyle(
              color: Theme.of(context).colorScheme.onPrimaryContainer,
              decoration: TextDecoration.underline,
            ),
          ),
        ),
        inComingChatBubbleConfig: chatview.ChatBubble(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          border: incomingBubbleBorder,
          // Match outgoing base radii (grouping corners preserved by fork p15).
          shortMessageBorderRadius: 16,
          longMessageBorderRadius: 16,
          textStyle: TextStyle(
            color: Theme.of(context).colorScheme.onSurface,
          ),
          emojiSize: emojiInlineSize,
          // See outgoing: override the package's hardcoded Colors.black54
          // timestamp, which is unreadable on the dark bubble in dark mode.
          messageTimeTextStyle: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          linkPreviewConfig: chatview.LinkPreviewConfiguration(
            linkStyle: TextStyle(
              color: Theme.of(context).colorScheme.primary,
              decoration: TextDecoration.underline,
            ),
          ),
        ),
      ),
      messageConfig: messageConfiguration,
      profileCircleConfig: const chatview.ProfileCircleConfiguration(
        profileImageUrl: null,
      ),
      repliedMessageConfig: chatview.RepliedMessageConfiguration(
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
        verticalBarColor: Theme.of(context).colorScheme.primary,
        // The quoted text defaults to Colors.black in the package — invisible
        // on the dark surfaceContainerHighest background in dark mode.
        textStyle: TextStyle(color: Theme.of(context).colorScheme.onSurface),
        replyTitleTextStyle: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: 14,
          letterSpacing: 0.3,
        ),
        micIconColor: Theme.of(context).colorScheme.onSurfaceVariant,
        repliedMsgAutoScrollConfig: chatview.RepliedMsgAutoScrollConfig(
          enableHighlightRepliedMsg: true,
          highlightColor: Theme.of(context)
              .colorScheme
              .secondaryContainer
              .withValues(alpha: 0.6),
          // No scale bump — the instant 1.05 scale read as the bubble/view
          // "stretching" weirdly. A colour-only pulse (blinked 3× in the fork)
          // is cleaner.
          highlightScale: 1.0,
        ),
        loadOldReplyMessage: (replyId) async {
          while (state.hasMoreMessages) {
            await controller.loadMoreMessages();
            if (state.messages.any((m) => m.id == replyId)) {
              break;
            }
          }
        },
      ),
    );

    // App-side "jump to end of chat" button. We render our OWN standalone,
    // self-positioning widget instead of chatview's enableScrollToBottomButton:
    // with a custom sendMessageBuilder the package button lands in a layer whose
    // taps fall through to the message underneath (opens the tapped photo/video).
    // The widget aligns + themes itself (see ChatScrollToBottomButton).
    final scrollButton = Positioned.fill(
      child: ChatScrollToBottomButton(
        chatController: controller.chatController,
        alignment: ChatScrollButtonAlignment.right,
      ),
    );

    // Keyboard-on-scroll dismissal is now handled inside chatview via
    // ChatBackgroundConfiguration.scrollViewKeyboardDismissBehavior (fork
    // addition) — no NotificationListener wrapper needed here anymore.
    if (wallpaper == null) {
      return Stack(children: [Positioned.fill(child: chatView), scrollButton]);
    }
    // Paint the theme wallpaper behind the (transparent) chat surface.
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerLowest,
        ),
        Positioned.fill(
          child: wallpaper.endsWith('.svg')
              ? SvgPicture.asset(wallpaper, fit: BoxFit.cover)
              : Image.asset(wallpaper, fit: BoxFit.cover),
        ),
        Positioned.fill(child: chatView),
        scrollButton,
      ],
    );
  }

  /// Localized "seen" line under the newest read message (replaces the
  /// package default's hardcoded English "Seen now" / timeago strings).
  Widget _buildLastSeen(chatview.Message message, String formattedDate) {
    final readAt = message.createdAt;
    final locale = context.locale.toString();
    final String text;
    if (AppTime.minutesAgo(readAt) < 1) {
      text = 'chat_view.seen_now'.tr();
    } else if (AppTime.isSameDayAsNow(readAt)) {
      text = 'chat_view.seen_at'.tr(args: [AppTime.hm(readAt, locale)]);
    } else {
      text = 'chat_view.seen_at'.tr(args: [AppTime.dayHm(readAt, locale)]);
    }
    return Padding(
      padding: const EdgeInsets.all(2),
      child: Text(
        '$text    ',
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: 12,
        ),
      ),
    );
  }

  /// Status ticks beside own bubbles: clock while pending, ✓ sent,
  /// ✓✓ delivered, ✓✓ tinted once every recipient has read it.
  Widget _buildReceipt(chatview.MessageStatus status) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color) = switch (status) {
      chatview.MessageStatus.pending => (
          Icons.access_time,
          scheme.onSurfaceVariant
        ),
      chatview.MessageStatus.undelivered => (Icons.done, scheme.onSurfaceVariant),
      chatview.MessageStatus.delivered => (
          Icons.done_all,
          scheme.onSurfaceVariant
        ),
      chatview.MessageStatus.read => (Icons.done_all, scheme.primary),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Icon(icon, size: 15, color: color),
    );
  }

  /// Long-press or double-tap on a bubble opens the unified message-actions
  /// sheet. Which entries appear depends on ownership and message type.
  void _showMessageActions(
    ChatViewController controller,
    ChatViewState state,
    chatview.Message message,
  ) {
    if (message.sentBy == systemId) return;
    if (state.isPending || state.isNotMember) return;

    final isOwn = message.sentBy == state.currentUserId;
    final isMedia = MediaAttachment.tryParse(message.message) != null;
    // Link-containing texts are MessageType.custom (LinkMessageBubble) but
    // behave like text for reply/copy/edit purposes.
    final isText = message.messageType == chatview.MessageType.text ||
        (message.messageType == chatview.MessageType.custom && !isMedia);
    final canSend = state.usernames.length > 1 && !state.isNotMember;
    // Undecrypted messages render the localized placeholder — nothing to
    // forward or copy there.
    final isDecrypted = message.message != 'chat_view.encrypted'.tr();

    showMessageActionsSheet(
      context: context,
      ref: ref,
      chatId: widget.chatId,
      message: message,
      onReply: canSend && (isText || isMedia)
          ? () => _textFieldKey.currentState?.assignReplyMessage(message)
          : null,
      onForward: (isText || isMedia) && isDecrypted
          ? () => _forwardMessage(message)
          : null,
      copyText: isText ? message.message : null,
      onEdit: isOwn && isText
          ? () => _showEditDialog(context, controller, message)
          : null,
      onUnsend: isOwn
          ? () => controller.deleteMessageForEveryone(message.id)
          : null,
      // "Info" → per-recipient delivered/read times (also the discoverable
      // path in 1:1s, where the swipe only peeks). Only when the underlying
      // message is loaded (has the receipt maps).
      onInfo: _chattrMessage(state, message.id) != null
          ? () => _openTimestampInfo(state, message)
          : null,
    );
  }

  /// The underlying chattr message (with per-recipient received/read maps) for a
  /// chatview bubble; null for system rows or if it scrolled out of the page.
  Message? _chattrMessage(ChatViewState state, String id) {
    for (final m in state.messages) {
      if (m.id == id && m is Message) return m;
    }
    return null;
  }

  /// Opens the per-recipient timestamp sheet for a bubble (Slide-to-Timestamp).
  void _openTimestampInfo(ChatViewState state, chatview.Message message) {
    final m = _chattrMessage(state, message.id);
    if (m == null) return;
    showTimestampInfoSheet(
      context: context,
      chatId: widget.chatId,
      message: m,
      usernames: state.usernames,
      currentUserId: state.currentUserId,
      showReadReceipts: ref.read(sendReadReceiptsProvider),
    );
  }

  /// Forward a message: pick a target chat, then re-send text or media into
  /// it (media is downloaded, decrypted and re-sent with a fresh key).
  Future<void> _forwardMessage(chatview.Message message) async {
    final targetChatId = await showForwardChatSheet(
      context: context,
      excludeChatId: widget.chatId,
    );
    if (targetChatId == null || !mounted) return;

    final forwardService = MessageForwardService(ref);
    try {
      final album = MediaAlbum.tryParse(message.message);
      if (album != null) {
        await forwardService.forwardAlbum(targetChatId, album);
      } else {
        await forwardService.forwardText(targetChatId, message.message);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('chat_view.forwarded'.tr())),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('chat_view.send_error'.tr(args: ['$e']))),
        );
      }
    }
  }

  void _showEditDialog(
    BuildContext context,
    ChatViewController controller,
    chatview.Message message,
  ) {
    final editController = TextEditingController(text: message.message);
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('chat_view.edit_message'.tr()),
        content: TextField(
          controller: editController,
          autofocus: true,
          maxLines: null,
          decoration: InputDecoration(
            hintText: 'chat_view.type_message'.tr(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text('chat_view.cancel'.tr()),
          ),
          FilledButton(
            onPressed: () async {
              final newText = editController.text.trim();
              Navigator.pop(dialogContext);
              if (newText.isEmpty || newText == message.message) return;
              try {
                await controller.editMessage(message.id, newText);
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('chat_view.send_error'.tr(args: ['$e']))),
                  );
                }
              }
            },
            child: Text('chat_detail.save_changes'.tr()),
          ),
        ],
      ),
    );
  }

  Widget Function(chatview.Message) _customMessageBuilder(
    BuildContext context,
    ChatViewState state,
  ) {
    return (message) {
      // "Unread messages" divider (#108) — a synthetic row, not a real message.
      if (message.id == unreadDividerMessageId) {
        final scheme = Theme.of(context).colorScheme;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Divider(color: scheme.primary.withValues(alpha: 0.4)),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  'chat_view.unread_divider'.tr(),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: scheme.primary,
                  ),
                ),
              ),
              Expanded(
                child: Divider(color: scheme.primary.withValues(alpha: 0.4)),
              ),
            ],
          ),
        );
      }
      // Encrypted media message: a single attachment (image inline / file card)
      // or a multi-item album mosaic (#109). Both carry the optional caption.
      final album = MediaAlbum.tryParse(message.message);
      if (album != null) {
        final isOwn = message.sentBy == state.currentUserId;
        // The fork stacks the reaction pill at bottom:0 of the custom widget
        // (unlike text/image bubbles it reserves NO space) → on media it would
        // overlap the content. Reserve bottom space when reactions exist so the
        // overlaid pill lands below the media instead of on top of it.
        final hasReactions = message.reaction.reactions.isNotEmpty;
        return Padding(
          padding: EdgeInsets.only(
            left: 4,
            right: 4,
            top: 2,
            bottom: hasReactions ? 18 : 2,
          ),
          child: album.isAlbum
              ? MediaAlbumView(album: album, isOwn: isOwn)
              : MediaMessageView(
                  attachment: album.first,
                  caption: album.caption,
                  isOwn: isOwn,
                ),
        );
      }
      // Markdown-formatted text → render the safe subset. Before the link path
      // so `[text](url)` renders as a formatted link (SafeMarkdown linkifies
      // bare URLs itself, so plain http(s) stays tappable here too).
      if (message.sentBy != systemId && hasMarkdown(message.message)) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: MarkdownMessageBubble(
            message: message,
            isOwn: message.sentBy == state.currentUserId,
          ),
        );
      }
      // Text with URLs: compact favicon+title preview instead of chatview's
      // AnyLinkPreview card.
      if (message.sentBy != systemId &&
          extractUrls(message.message).isNotEmpty) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: LinkMessageBubble(
            message: message,
            isOwn: message.sentBy == state.currentUserId,
          ),
        );
      }
      if (message.sentBy == systemId) {
        return Center(
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              message.message,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
        );
      }
      return Text(message.message);
    };
  }
}
