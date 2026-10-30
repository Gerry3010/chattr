// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// This component is a deliberate re-implementation of chatview's built-in text
// field (to add reply suggestions, custom send handling, etc.). It builds on
// the composer surface the chatview fork exposes publicly via
// `package:chatview/composer.dart` — no `package:chatview/src/...` imports, so
// an upstream internal refactor can't silently break it.

import 'dart:io' show Platform;

import 'package:chatview/composer.dart';
import 'package:chatview_utils/chatview_utils.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/media/media_attachment.dart';
import '../../../features/media/media_preview_label.dart';
import '../../../features/mentions/mention_utils.dart';
import '../../../features/profiles/widgets/user_avatar.dart';
import '../../../features/settings/markdown_bar_controller.dart';
import '../../../features/messages/message_markdown.dart';
import 'markdown_composer_toolbar.dart';
import 'safe_markdown.dart';
import '../../../features/places/place_preview_label.dart';
import '../../../features/messages/notice_preview_label.dart';
import '../../../features/messages/inline_emoji.dart';

class ChatViewTextField extends SendMessageWidget {
  final void Function(FocusNode)? initFocusNode;

  /// Reply set on chatview's own [SendMessageWidgetState] (by swipe-to-reply),
  /// forwarded through the `sendMessageBuilder` callback. Adopted in
  /// [ChatViewTextFieldState.didUpdateWidget] — without this, swiping a
  /// message to reply had no effect because the builder discarded the value.
  final ReplyMessage pendingReply;

  /// Fired on every composer text change; the parent debounces and persists
  /// it as the chat's draft. Sending clears the field, which reports '' here
  /// and thereby deletes the draft.
  final ValueChanged<String>? onDraftChanged;

  /// Group members who can be @-mentioned. Empty disables the typeahead (e.g. a
  /// 1:1 chat); non-empty drives the composer's mention suggestion list (1.10).
  final List<MentionCandidate> mentionCandidates;

  ChatViewTextField({
    super.key,
    StringMessageCallBack? onSendTap,
    required super.sendMessageConfig,
    super.messageConfig,
    super.replyMessageBuilder,
    this.initFocusNode,
    this.onDraftChanged,
    this.mentionCandidates = const [],
    this.pendingReply = const ReplyMessage(),
  }) : super(onSendTap: onSendTap ?? (message, replyMessage, messageType) {});

  @override
  ChatViewTextFieldState createState() => ChatViewTextFieldState();
}

class ChatViewTextFieldState extends State<ChatViewTextField> {
  final _textEditingController = EmojiTextEditingController();

  final _focusNode = FocusNode(debugLabel: 'chat_composer');

  FocusNode get focusNode => _focusNode;

  final GlobalKey<ReplyMessageViewState> _replyMessageTextFieldViewKey =
      GlobalKey();

  final GlobalKey<SelectedImageViewWidgetState> _selectedImageViewWidgetKey =
      GlobalKey();
  ReplyMessage _replyMessage = const ReplyMessage();

  ReplyMessage get replyMessage => _replyMessage;

  /// Whether the live Markdown preview panel is expanded (toolbar eye toggle).
  bool _previewEnabled = false;

  ChatUser? currentUser;

  /// @-mention typeahead (1.10): the members matching the token being typed
  /// (empty = hidden) and the token itself (for the insertion).
  List<MentionCandidate> _mentionSuggestions = const [];
  MentionQuery? _activeMention;

  @override
  void initState() {
    super.initState();
    widget.initFocusNode?.call(_focusNode);
    _textEditingController.addListener(_notifyDraftChanged);
    _textEditingController.addListener(_updateMentionSuggestions);
  }

  void _notifyDraftChanged() {
    widget.onDraftChanged?.call(_textEditingController.text);
  }

  /// Recomputes the @-mention suggestion list from the caret position. Fires on
  /// every text/selection change; a no-op when there are no candidates (1:1).
  void _updateMentionSuggestions() {
    if (widget.mentionCandidates.isEmpty) return;
    final sel = _textEditingController.selection;
    if (!sel.isValid || !sel.isCollapsed) {
      _clearMentionSuggestions();
      return;
    }
    final query = activeMentionQuery(
      _textEditingController.text,
      sel.baseOffset,
    );
    if (query == null) {
      _clearMentionSuggestions();
      return;
    }
    final matches = filterMentionCandidates(
      query.query,
      widget.mentionCandidates,
    );
    if (matches.isEmpty) {
      _clearMentionSuggestions();
      return;
    }
    setState(() {
      _activeMention = query;
      _mentionSuggestions = matches;
    });
  }

  void _clearMentionSuggestions() {
    if (_mentionSuggestions.isEmpty && _activeMention == null) return;
    setState(() {
      _mentionSuggestions = const [];
      _activeMention = null;
    });
  }

  /// Inserts the chosen member's `@username ` in place of the typed token.
  void _selectMention(MentionCandidate c) {
    final q = _activeMention;
    final sel = _textEditingController.selection;
    if (q == null || !sel.isValid || !sel.isCollapsed) return;
    final r = applyMention(
      _textEditingController.text,
      q,
      sel.baseOffset,
      c.username,
    );
    _textEditingController.value = TextEditingValue(
      text: r.text,
      selection: TextSelection.collapsed(offset: r.cursor),
    );
    _clearMentionSuggestions();
    FocusScope.of(context).requestFocus(_focusNode);
  }

  /// Restores a persisted draft into the (still empty) composer. No-op when
  /// the user already typed something — a late-arriving draft must not
  /// overwrite live input.
  void seedDraft(String text) {
    if (_textEditingController.text.isNotEmpty) return;
    _textEditingController.text = text;
  }

  /// Current composer text — used to prefill a media caption from what the user
  /// already typed (#6).
  String get text => _textEditingController.text;

  /// Clears the composer (and, via the listener, the persisted draft). Called
  /// after a media caption send consumes the typed text.
  void clearText() => _textEditingController.clear();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (chatViewIW != null) {
      currentUser = chatViewIW!.chatController.currentUser;
    }
  }

  @override
  void didUpdateWidget(covariant ChatViewTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    final incoming = widget.pendingReply;
    // Adopt a reply delivered by chatview's swipe-to-reply. Empty values are
    // ignored (they are the parent's reset state, not a "clear reply" signal),
    // and unchanged values are ignored so unrelated parent rebuilds don't
    // re-open a reply the user already closed.
    if (incoming.messageId.isEmpty ||
        incoming.messageId == oldWidget.pendingReply.messageId) {
      return;
    }
    _adoptPendingReply(incoming);
  }

  void _adoptPendingReply(ReplyMessage reply) {
    FocusScope.of(context).requestFocus(_focusNode);
    _replyMessage = _sanitizedReply(reply);

    if (_replyMessageTextFieldViewKey.currentState == null) {
      setState(() {});
    } else {
      _replyMessageTextFieldViewKey.currentState!.replyMessage.value =
          _replyMessage;
    }

    // Reset the package-side copy so swiping the SAME message again still
    // reaches us (our didUpdateWidget guard compares message ids). The parent
    // rebuild passes an empty pendingReply, which the guard above ignores.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.findAncestorStateOfType<SendMessageWidgetState>()?.onCloseTap();
    });
  }

  /// Media messages carry their [MediaAttachment] JSON descriptor as message
  /// text — show a readable label in the reply preview instead. Only the
  /// preview is affected; sending a reply references the message by id.
  ReplyMessage _sanitizedReply(ReplyMessage reply) {
    final album = MediaAlbum.tryParse(reply.message);
    final label = noticePreviewLabel(reply.message) ??
        shotPreviewLabel(reply.message) ??
        (album != null
            ? mediaPreviewLabel(album)
            : placePreviewLabel(reply.message));
    if (label == null) return reply;
    return ReplyMessage(
      message: label,
      replyBy: reply.replyBy,
      replyTo: reply.replyTo,
      messageType: reply.messageType,
      messageId: reply.messageId,
      voiceMessageDuration: reply.voiceMessageDuration,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scrollToBottomButtonConfig =
        chatListConfig.scrollToBottomButtonConfig;

    // We are always rendered via chatview's `sendMessageBuilder`, so the package
    // already wraps us in `Align(bottomCenter) > Builder(key: chatTextFieldViewKey)`.
    // That Builder measures OUR height to inset the message list. Therefore we must:
    //  (a) NOT re-assign chatTextFieldViewKey ourselves — doing so put the same
    //      GlobalKey on two widgets → 2069x "Multiple widgets used the same
    //      GlobalKey"; and
    //  (b) return content sized to the text field only (no full-height Align/Stack)
    //      — otherwise the package measures the whole screen height and messages
    //      bunch at the top.
    // Column, not Stack (fork p20): the reply banner / selected-image strip sit
    // in flow ABOVE the field, so a growing multi-line draft can no longer
    // paint over them (the old Stack let the field cover the banner).
    final inputStack = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ReplyMessageView(
          key: _replyMessageTextFieldViewKey,
          sendMessageConfig: widget.sendMessageConfig,
          messageConfig: widget.messageConfig,
          builder: widget.replyMessageBuilder,
          onChange: (value) => _replyMessage = value,
        ),
        if (widget.sendMessageConfig.shouldSendImageWithText)
          SelectedImageViewWidget(
            key: _selectedImageViewWidgetKey,
            sendMessageConfig: widget.sendMessageConfig,
          ),
        ChatUITextField(
          focusNode: _focusNode,
          textEditingController: _textEditingController,
          onPressed: _onPressed,
          sendMessageConfig: widget.sendMessageConfig,
          onRecordingComplete: _onRecordingComplete,
          onImageSelected: (images, messageId) {
            if (widget.sendMessageConfig.shouldSendImageWithText) {
              if (images.isNotEmpty) {
                _selectedImageViewWidgetKey.currentState?.selectedImages.value =
                    [
                      ...?_selectedImageViewWidgetKey
                          .currentState
                          ?.selectedImages
                          .value,
                      images,
                    ];

                FocusScope.of(context).requestFocus(_focusNode);
              }
            } else {
              _onImageSelected(images, '');
            }
          },
        ),
      ],
    );

    final textField = Padding(
      padding: EdgeInsets.fromLTRB(
        bottomPadding4,
        bottomPadding4,
        bottomPadding4,
        _bottomPadding,
      ),
      // The Markdown toolbar + live preview live in a Column so they are part of
      // the MEASURED composer height (the message list insets by it — see the
      // chatTextFieldViewKey note above). The Column is sized to its children,
      // never full-height, so the measurement stays correct.
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Live Markdown preview above the input — only when the styling bar is
          // enabled AND preview toggled on (default off) AND the draft actually
          // contains formatting. Rebuilds on text change only.
          Consumer(
            builder: (context, ref, _) {
              if (!ref.watch(markdownBarEnabledProvider)) {
                return const SizedBox.shrink();
              }
              return ValueListenableBuilder<TextEditingValue>(
                valueListenable: _textEditingController,
                builder: (context, value, _) {
                  if (value.text.isEmpty ||
                      !_previewEnabled ||
                      !hasMarkdown(value.text)) {
                    return const SizedBox.shrink();
                  }
                  return _buildMarkdownPreview(context, value.text);
                },
              );
            },
          ),
          // @-mention typeahead (1.10) — just above the input, part of the
          // measured composer height so the message list insets correctly.
          _buildMentionBar(context),
          inputStack,
          // Formatting toolbar BELOW the field (iOS inputAccessoryView spot).
          // iOS anchors its text-selection menu (Cut/Copy/Look up) just ABOVE
          // the selection — i.e. over anything directly above the field. With
          // the toolbar below, that menu no longer covers it, and a selection
          // can actually be formatted (tap Bold). Shown once there's text.
          // Markdown formatting bar — hidden unless the user enabled it globally
          // from the composer context menu (default off; markdown rendering
          // still works regardless).
          Consumer(
            builder: (context, ref, _) {
              if (!ref.watch(markdownBarEnabledProvider)) {
                return const SizedBox.shrink();
              }
              return ValueListenableBuilder<TextEditingValue>(
                valueListenable: _textEditingController,
                builder: (context, value, _) {
                  if (value.text.isEmpty) return const SizedBox.shrink();
                  return MarkdownComposerToolbar(
                    controller: _textEditingController,
                    focusNode: _focusNode,
                    previewEnabled: _previewEnabled,
                    onTogglePreview: () =>
                        setState(() => _previewEnabled = !_previewEnabled),
                  );
                },
              );
            },
          ),
        ],
      ),
    );

    final showScrollToBottom =
        chatViewIW?.featureActiveConfig.enableScrollToBottomButton ?? true;
    if (!showScrollToBottom) return textField;

    // Float the scroll-to-bottom button just above the text field WITHOUT adding
    // to the measured height. (The button always occupies layout space — it only
    // Transform.scale-s away when hidden — so putting it in the measured subtree
    // would leave a permanent gap above the field.) The Stack is sized by
    // `textField`; the button is an overlay pinned to the top edge and shifted up
    // by its own height via FractionalTranslation, with Clip.none so it paints
    // outside the bounds.
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.bottomCenter,
      children: [
        textField,
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: FractionalTranslation(
            translation: const Offset(0, -1),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Padding(
                  padding:
                      scrollToBottomButtonConfig?.padding ?? EdgeInsets.zero,
                  child: const ScrollToBottomButton(),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Live preview of how the composed Markdown will render, reusing the same
  /// SafeMarkdown renderer as the message bubbles (#95 phase 1). Height-capped
  /// and scrollable so a long draft never balloons the composer.
  Widget _buildMarkdownPreview(BuildContext context, String text) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 140),
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: SingleChildScrollView(
        child: SafeMarkdown(
          data: text,
          textColor: scheme.onSurface,
          linkColor: scheme.primary,
        ),
      ),
    );
  }

  /// The @-mention typeahead list shown just above the input (1.10). Part of the
  /// measured composer Column so the message list insets correctly.
  Widget _buildMentionBar(BuildContext context) {
    if (_mentionSuggestions.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 200),
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListView.builder(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: _mentionSuggestions.length,
        itemBuilder: (context, i) {
          final c = _mentionSuggestions[i];
          return ListTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            leading: c.isGroup
                ? CircleAvatar(
                    radius: 16,
                    backgroundColor: scheme.primaryContainer,
                    child: Icon(
                      Icons.groups,
                      size: 18,
                      color: scheme.onPrimaryContainer,
                    ),
                  )
                : UserAvatar(userId: c.id, radius: 16),
            title: Text(
              '@${c.username}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: c.isGroup
                  ? const TextStyle(fontWeight: FontWeight.w600)
                  : null,
            ),
            onTap: () => _selectMention(c),
          );
        },
      ),
    );
  }

  void _onRecordingComplete(String? path) {
    if (path != null) {
      _onSendTap.call(path, _replyMessage, MessageType.voice);
      onCloseTap();
    }
  }

  void _onImageSelected(String imagePath, String error) {
    if (imagePath.isEmpty) return;

    _onSendTap.call(imagePath, _replyMessage, MessageType.image);
    _assignRepliedMessage();
  }

  void _assignRepliedMessage() {
    if (_replyMessage.message.isEmpty) return;
    _replyMessage = const ReplyMessage();
  }

  void _onPressed() {
    final messageText = _textEditingController.text.trim();
    _textEditingController.clear();
    if (messageText.isEmpty) return;

    if (_selectedImageViewWidgetKey.currentState?.selectedImages.value
        case final selectedImages?) {
      for (final image in selectedImages) {
        _onImageSelected(image, '');
      }
      _selectedImageViewWidgetKey.currentState?.selectedImages.value = [];
    }

    _onSendTap.call(messageText.trim(), _replyMessage, MessageType.text);
    onCloseTap();
  }

  void assignReplyMessage(Message message) {
    if (currentUser == null) {
      return;
    }
    FocusScope.of(context).requestFocus(_focusNode);
    _replyMessage = _sanitizedReply(
      ReplyMessage(
        message: message.message,
        replyBy: currentUser!.id,
        replyTo: message.sentBy,
        messageType: message.messageType,
        messageId: message.id,
        voiceMessageDuration: message.voiceMessageDuration,
      ),
    );

    if (_replyMessageTextFieldViewKey.currentState == null) {
      setState(() {});
    } else {
      _replyMessageTextFieldViewKey.currentState!.replyMessage.value =
          _replyMessage;
    }
  }

  /// Put a message back that could not be sent (CHAT-63). The field is
  /// cleared the moment send is tapped, so without this an offline send lost
  /// the text and its quote. Whatever was typed since stays, below the
  /// restored text.
  void restoreUnsent(String text, ReplyMessage reply) {
    final typed = _textEditingController.text;
    final restored = typed.trim().isEmpty ? text : '$text\n$typed';
    _textEditingController.value = TextEditingValue(
      text: restored,
      selection: TextSelection.collapsed(offset: restored.length),
    );
    if (reply.messageId.isNotEmpty && _replyMessage.messageId.isEmpty) {
      _replyMessage = reply;
      if (_replyMessageTextFieldViewKey.currentState == null) {
        setState(() {});
      } else {
        _replyMessageTextFieldViewKey.currentState!.replyMessage.value =
            _replyMessage;
      }
    }
  }

  void onCloseTap() {
    if (_replyMessageTextFieldViewKey.currentState == null) {
      setState(() {
        _replyMessage = const ReplyMessage();
      });
    } else {
      _replyMessageTextFieldViewKey.currentState?.onClose();
    }
  }

  double get _bottomPadding => (!kIsWeb && Platform.isIOS)
      ? (_focusNode.hasFocus
            ? bottomPadding1
            : View.of(context).viewPadding.bottom > 0
            ? bottomPadding2
            : bottomPadding3)
      : bottomPadding3;

  StringMessageCallBack get _onSendTap => (m, r, t) {
    if (suggestionsConfig?.autoDismissOnSelection ?? true) {
      chatViewIW?.chatController.removeReplySuggestions();
    }

    chatViewIW?.chatController.scrollToLastMessage();
    return widget.onSendTap(m, r, t);
  };

  @override
  void dispose() {
    _textEditingController.removeListener(_notifyDraftChanged);
    _textEditingController.removeListener(_updateMentionSuggestions);
    _textEditingController.dispose();
    _focusNode.dispose();
    super.dispose();
  }
}

extension ChattrUITextField on ChatUITextField {}
