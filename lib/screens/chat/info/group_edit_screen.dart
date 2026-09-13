// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../features/chats/chat_model.dart';
import '../../../features/chats/chats_controller.dart';
import '../../../features/chats/group_avatar_actions.dart';
import '../../../features/chats/widgets/group_avatar.dart';

/// "Edit group" — picture, name, description in ONE place.
///
/// Before, that was done in the info view itself: a pencil per field, a check
/// and a cross in the editing state, plus a camera badge on the picture.
/// Whoever only wanted to check what the group is called saw mostly tooling —
/// and non-admins saw a view that differed structurally from the admins'. Now
/// the info looks the same for everyone, and the tooling lies behind a pencil.
class GroupEditScreen extends HookConsumerWidget {
  final Chat chat;

  const GroupEditScreen({super.key, required this.chat});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watch the living chat: the picture is uploaded immediately (not only on
    // save), and the new path comes back through the controller — with the
    // snapshot from the constructor the old picture would remain.
    final live = ref.watch(chatProvider(chat.id)) ?? chat;

    final nameCtrl = useTextEditingController(text: live.name ?? '');
    final descCtrl = useTextEditingController(text: live.description ?? '');
    final name = useValueListenable(nameCtrl).text;
    final desc = useValueListenable(descCtrl).text;
    final saving = useState(false);

    final nameChanged = name.trim() != (live.name ?? '').trim();
    final descChanged = desc.trim() != (live.description ?? '').trim();
    final nameValid = name.trim().length >= 2;
    final canSave = !saving.value && nameValid && (nameChanged || descChanged);

    Future<void> save() async {
      saving.value = true;
      final controller = ref.read(chatsControllerProvider.notifier);
      final messenger = ScaffoldMessenger.of(context);
      final navigator = Navigator.of(context);

      if (nameChanged) {
        await controller.updateChatName(chat: live, newName: name.trim());
      }
      if (descChanged) {
        await controller.updateChatDescription(
          chat: live,
          newDescription: desc.trim(),
        );
      }
      saving.value = false;

      // TRAP: `updateChatName` and `updateChatDescription` DO NOT THROW — they
      // log the error and return. A blind "saved" would therefore be a claim
      // here, not a statement. So it checks whether the value really arrived.
      final nun = ref.read(chatProvider(chat.id));
      final ok = nun != null &&
          (!nameChanged || (nun.name ?? '') == name.trim()) &&
          (!descChanged ||
              (nun.description ?? '') == desc.trim());

      if (!ok) {
        messenger.showSnackBar(
          SnackBar(
            content: Text('group_edit.save_failed'.tr()),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }
      messenger.showSnackBar(SnackBar(content: Text('group_edit.saved'.tr())));
      navigator.pop();
    }

    return PopScope(
      canPop: !(nameChanged || descChanged),
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final verwerfen = await _confirmDiscard(context);
        if (verwerfen == true && context.mounted) Navigator.pop(context);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text('group_edit.title'.tr()),
          actions: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: FilledButton(
                onPressed: canSave ? save : null,
                child: Text('group_edit.save'.tr()),
              ),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Center(child: _AvatarPicker(chat: live)),
            const SizedBox(height: 24),
            TextField(
              controller: nameCtrl,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: 'group_edit.name_label'.tr(),
                border: const OutlineInputBorder(),
                // The error only appears once too little has really been typed
                // — not already in the empty field on opening.
                errorText: (name.isNotEmpty && !nameValid)
                    ? 'group_edit.name_too_short'.tr()
                    : null,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: descCtrl,
              maxLines: null,
              minLines: 3,
              decoration: InputDecoration(
                labelText: 'group_edit.description_label'.tr(),
                hintText: 'chat_detail.description_hint'.tr(),
                border: const OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<bool?> _confirmDiscard(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('group_edit.discard_title'.tr()),
        content: Text('group_edit.discard_message'.tr()),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('common.cancel'.tr()),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text('group_edit.discard_confirm'.tr()),
          ),
        ],
      ),
    );
  }
}

/// Large group picture with a camera badge.
///
/// The picture is uploaded IMMEDIATELY, not only on save — the previous route,
/// adopted unchanged. Sending a picture later would mean storing it somewhere
/// until then, and for media in this app that is deliberately provided for
/// nowhere.
class _AvatarPicker extends ConsumerWidget {
  final Chat chat;

  const _AvatarPicker({required this.chat});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Stack(
      alignment: Alignment.bottomRight,
      children: [
        GroupAvatar(
          chatId: chat.id,
          radius: 56,
          onTap: () => showGroupAvatarViewer(context, chat.id),
        ),
        Material(
          color: Theme.of(context).colorScheme.primary,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () => _showActions(context, ref),
            child: const Padding(
              padding: EdgeInsets.all(6),
              child: Icon(Icons.photo_camera, size: 18, color: Colors.white),
            ),
          ),
        ),
      ],
    );
  }

  void _showActions(BuildContext context, WidgetRef ref) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera),
              title: Text('chat_detail.avatar_camera'.tr()),
              onTap: () {
                Navigator.pop(sheetContext);
                captureAndUploadGroupAvatar(context, ref, chat);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: Text('chat_detail.avatar_change'.tr()),
              onTap: () {
                Navigator.pop(sheetContext);
                pickAndUploadGroupAvatar(context, ref, chat);
              },
            ),
            if (chat.avatarPath != null)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: Text('chat_detail.avatar_remove'.tr()),
                onTap: () {
                  Navigator.pop(sheetContext);
                  ref
                      .read(chatsControllerProvider.notifier)
                      .clearGroupAvatar(chat: chat);
                },
              ),
          ],
        ),
      ),
    );
  }
}
