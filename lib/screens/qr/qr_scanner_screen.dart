// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:chattr/features/chats/chats.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import '../../core/navigation/app_page_route.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../features/auth/auth_controller.dart';
import '../../features/identity/identity_verification_repository.dart';
import '../../core/logging/logger_service.dart';
import '../../core/security/kem_key_signer.dart';
import '../../core/security/security_providers.dart';
import 'qr_display_screen.dart';

class QrScannerScreen extends ConsumerStatefulWidget {
  /// When set, scanning a user QR adds that user to this group instead of
  /// starting a 1:1 chat. The added member has no per-chat key yet; their app
  /// self-heals (registers its key) when it next sees the group — same as a
  /// normal join.
  final String? addToChatId;

  /// Open directly in manual-ID-entry mode without touching the camera
  /// (used by the "enter code" entry in the new-chat dialog).
  final bool startWithManualInput;

  const QrScannerScreen({
    super.key,
    this.addToChatId,
    this.startWithManualInput = false,
  });

  @override
  ConsumerState<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends ConsumerState<QrScannerScreen> {
  MobileScannerController? controller;
  bool isProcessing = false;

  /// True only when the camera actually threw — drives the
  /// "camera unavailable" hint. Deliberately manual entry sets
  /// [showManualInput] instead (it used to abuse this flag, so the screen
  /// always claimed the camera was missing).
  bool hasError = false;
  bool showManualInput = false;
  String? errorMessage;
  final TextEditingController _manualIdController = TextEditingController();

  @override
  void initState() {
    super.initState();
    showManualInput = widget.startWithManualInput;
    // In manual mode don't start (or permission-prompt for) the camera at
    // all; it initializes lazily if the user switches to scanning.
    if (!widget.startWithManualInput) {
      _initializeScanner();
    }
  }

  Future<void> _initializeScanner() async {
    try {
      // autoStart: false — the MobileScanner widget (mobile_scanner 7) would
      // otherwise also start the controller, racing our manual start() below and
      // throwing MobileScannerException(controllerInitializing). We start it
      // ourselves so the try/catch here can surface camera failures.
      controller = MobileScannerController(autoStart: false);
      await controller!.start();
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        setState(() {
          hasError = true;
          showManualInput = true;
          errorMessage = e.toString();
        });
      }
    }
  }

  @override
  void dispose() {
    controller?.dispose();
    _manualIdController.dispose();
    super.dispose();
  }

  /// Switch from manual entry back to the camera scanner, initializing the
  /// camera lazily when the screen was opened in manual-only mode.
  void _switchToScanner() {
    setState(() => showManualInput = false);
    if (controller == null) _initializeScanner();
  }

  void _showMyQr(BuildContext context) {
    Navigator.push(
      context,
      appPageRoute<void>(builder: (_) => const QrDisplayScreen()),
    );
  }

  Future<void> _handleManualId() async {
    final id = _manualIdController.text.trim();

    if (id.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('qr.enter_id'.tr()),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    // Validate UUID format (basic check)
    if (id.length < 10) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('qr.invalid_id'.tr()),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    // Admin add-to-group mode: the manual entry is the USER id to add.
    if (widget.addToChatId != null) {
      setState(() => isProcessing = true);
      try {
        await ref
            .read(chatMembersControllerProvider)
            .addMember(chatId: widget.addToChatId!, userId: id);
        if (mounted) {
          Navigator.pop(context, {'type': 'member_added', 'user_id': id});
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('qr.member_added'.tr(args: [id.substring(0, 8)])),
              backgroundColor: Colors.green,
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          setState(() => isProcessing = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('qr.error'.tr(args: ['$e'])),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
      return;
    }

    // Try to join as group chat first
    final chatController = ref.read(chatsControllerProvider.notifier);
    final currentUserId = ref.read(authControllerProvider);
    if (currentUserId == null) {
      // Guard BEFORE flipping isProcessing so the UI can't get stuck.
      logger.warning('Manual ID join attempted while not authenticated');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('qr.not_logged_in'.tr()),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() => isProcessing = true);
    logger.info('Manual ID join: requesting to join chat $id');

    try {
      final memberController = ref.read(chatMembersControllerProvider);
      final keyManager = ref.read(chatKeyPairManagerProvider);

      // Request to join — but if already a member / already pending, say so
      // instead of creating a bogus duplicate (and WITHOUT regenerating keys,
      // which would spuriously rotate an existing member's chat keys). The
      // keypair is generated lazily only when a request is actually made. For a
      // user ID this insert FK-violates and falls through to the 1:1 path below.
      final outcome = await memberController.requestToJoinChecked(
        chatId: id,
        userId: currentUserId,
        generatePublicKey: () async {
          await keyManager.generateKeyPairForChat(id);
          final pub = await keyManager.getPublicKey(id);
          if (pub == null) return null;
          // Identity-signed so co-members can verify it (audit C1).
          return ref.read(kemKeySignerProvider).sign(id, pub);
        },
      );
      await chatController.addChat(id);

      if (mounted) {
        Navigator.pop(context, {'type': 'group', 'chat_id': id});
        _showJoinOutcome(outcome, id.substring(0, 8));
      }
    } catch (e) {
      // If joining as group failed, treat as user ID. Log the group-join
      // error first — it may be the real problem (e.g. key generation
      // failing), not just "this was a user ID after all".
      logger.warning('Group join failed for $id, trying as user ID', error: e);
      try {
        final direct = await chatController.findOrCreateDirectChat(id);
        if (mounted) {
          Navigator.pop(context, {
            'type': 'user',
            'user_id': id,
            'chat_id': direct.id,
          });
          if (direct.existed) {
            _showInfoSnackBar('qr.direct_chat_exists'.tr());
          }
        }
      } catch (e2) {
        // Neither a joinable chat nor an existing user — surface it instead
        // of crashing with an unhandled FK violation.
        logger.error('Manual ID matched neither chat nor user: $id', error: e2);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                _isBlockedError(e2) ? 'qr.blocked_error'.tr() : 'qr.invalid_code'.tr(),
              ),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } finally {
      if (mounted) {
        setState(() => isProcessing = false);
      }
    }
  }

  void _handleQrCode(BarcodeCapture capture) async {
    if (isProcessing) return;

    final barcode = capture.barcodes.firstOrNull;
    if (barcode?.rawValue == null) return;

    setState(() => isProcessing = true);

    try {
      final data = jsonDecode(barcode!.rawValue!);
      final type = data['type'] as String?;

      if (type == 'chattr_user' && data['user_id'] != null) {
        final userId = data['user_id'] as String;
        final currentUserId = ref.read(authControllerProvider);
        if (currentUserId == null) {
          throw Exception('Not authenticated');
        }

        // Scanning a person's QR in-person is the strong verification channel
        // (audit C1): if it carries an identity key, pin it as *verified* so
        // this peer's per-chat keys and messages are trusted and a later
        // key change surfaces a warning.
        final scannedIdentityKey = data['ik'] as String?;
        if (scannedIdentityKey != null && scannedIdentityKey.isNotEmpty) {
          await ref
              .read(identityVerificationRepositoryProvider)
              .pin(userId, scannedIdentityKey, verified: true);
        }

        // Admin add-to-group mode: add the scanned user to the target group.
        if (widget.addToChatId != null) {
          logger.info(
            'User QR scanned: adding $userId to ${widget.addToChatId}',
          );
          await ref
              .read(chatMembersControllerProvider)
              .addMember(chatId: widget.addToChatId!, userId: userId);
          if (mounted) {
            Navigator.pop(context, {'type': 'member_added', 'user_id': userId});
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'qr.member_added'.tr(args: [userId.substring(0, 8)]),
                ),
                backgroundColor: Colors.green,
              ),
            );
          }
          return;
        }

        // Default: open the existing 1:1 with the scanned user, or create it.
        // findOrCreateDirectChat dedupes so re-scanning the same person reopens
        // the existing chat instead of spawning a duplicate.
        logger.info('User QR scanned: opening 1:1 chat with $userId');
        final chatController = ref.read(chatsControllerProvider.notifier);
        final direct = await chatController.findOrCreateDirectChat(userId);

        if (mounted) {
          Navigator.pop(context, {
            'type': 'user',
            'user_id': userId,
            'chat_id': direct.id,
          });

          if (direct.existed) {
            _showInfoSnackBar('qr.direct_chat_exists'.tr());
          } else {
            _showSnackBar(
              'qr.user_found'.tr(args: [userId.substring(0, 8)]),
              Colors.green,
            );
          }
        }
      } else if (type == 'chattr_group' && data['chat_id'] != null) {
        // Group Chat QR Code
        final chatId = data['chat_id'] as String;
        final chatName = data['chat_name'] as String?;

        if (mounted) {
          // Join the group chat
          await _joinGroupChat(chatId, chatName);
        }
      } else {
        throw Exception('Invalid QR code format');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _isBlockedError(e) ? 'qr.blocked_error'.tr() : 'qr.invalid_code'.tr(),
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
      setState(() => isProcessing = false);
    }
  }

  /// The 00031 block triggers raise with a message starting with 'blocked:'.
  bool _isBlockedError(Object e) => e.toString().contains('blocked:');

  Future<void> _joinGroupChat(String chatId, String? chatName) async {
    try {
      logger.info('Group QR scanned: requesting to join chat $chatId');
      final currentUserId = ref.read(authControllerProvider);
      if (currentUserId == null) {
        throw Exception('Not authenticated');
      }

      final memberController = ref.read(chatMembersControllerProvider);
      final chatsController = ref.read(chatsControllerProvider.notifier);
      final keyManager = ref.read(chatKeyPairManagerProvider);

      // Request to join — unless already a member / already pending. The keypair
      // is generated lazily only when a request is actually made, so an existing
      // member's chat keys aren't spuriously rotated.
      final outcome = await memberController.requestToJoinChecked(
        chatId: chatId,
        userId: currentUserId,
        generatePublicKey: () async {
          await keyManager.generateKeyPairForChat(chatId);
          final pub = await keyManager.getPublicKey(chatId);
          if (pub == null) return null;
          // Identity-signed so co-members can verify it (audit C1).
          return ref.read(kemKeySignerProvider).sign(chatId, pub);
        },
      );

      // 3. Immediately add chat to local state (shown as pending / member).
      await chatsController.addChat(chatId);

      if (mounted) {
        // Navigate back and show the chat (in pending / member state).
        Navigator.pop(context, {'type': 'group', 'chat_id': chatId});
        _showJoinOutcome(outcome, chatName ?? chatId.substring(0, 8));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('qr.join_error'.tr(args: [e.toString()])),
            backgroundColor: Colors.red,
          ),
        );
      }
      setState(() => isProcessing = false);
    }
  }

  /// Feedback for a checked group-join: distinguish a fresh request from
  /// "already a member" / "request already pending" so the user isn't confused.
  void _showJoinOutcome(JoinRequestOutcome outcome, String label) {
    if (!mounted) return;
    switch (outcome) {
      case JoinRequestOutcome.requested:
        // Surface the fresh request in the pending-requests overview / badge
        // right away (it's otherwise fetched lazily on next screen open).
        final uid = ref.read(authControllerProvider);
        if (uid != null) ref.invalidate(myPendingRequestsProvider(uid));
        _showSnackBar('qr.join_requested'.tr(args: [label]), Colors.orange);
      case JoinRequestOutcome.alreadyMember:
        _showInfoSnackBar('qr.already_member'.tr(args: [label]));
      case JoinRequestOutcome.alreadyPending:
        _showInfoSnackBar('qr.request_pending'.tr(args: [label]));
    }
  }

  /// A theme-aware info snackbar (readable in light AND dark — a hardcoded
  /// background gave dark text on a semi-blue fill in dark mode).
  void _showInfoSnackBar(String message) {
    if (!mounted) return;
    final scheme = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: TextStyle(color: scheme.onSecondaryContainer),
        ),
        backgroundColor: scheme.secondaryContainer,
      ),
    );
  }

  void _showSnackBar(String message, Color background) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: background),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Manual entry — either chosen deliberately or forced by a camera error.
    // Only a real camera exception shows the "camera unavailable" hint.
    if (showManualInput || hasError || controller == null) {
      return Scaffold(
        appBar: AppBar(
          title: Text('qr.manual_input_title'.tr()),
          actions: [
            if (!hasError)
              IconButton(
                icon: const Icon(Icons.qr_code_scanner),
                onPressed: _switchToScanner,
                tooltip: 'qr.scan_title'.tr(),
              ),
            IconButton(
              icon: const Icon(Icons.qr_code),
              onPressed: () => _showMyQr(context),
              tooltip: 'settings.my_qr'.tr(),
            ),
          ],
        ),
        // Scrollable so the open keyboard can't overflow the fixed column
        // (was "BOTTOM OVERFLOWED BY 25 PIXELS" on phones).
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(
                  hasError
                      ? Icons.camera_alt_outlined
                      : Icons.keyboard_alt_outlined,
                  size: 80,
                  color: Colors.grey[400],
                ),
                const SizedBox(height: 24),
                if (hasError) ...[
                  Text(
                    'qr.camera_unavailable'.tr(),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                ],
                Text(
                  'qr.manual_input_instruction_v2'.tr(),
                  textAlign: TextAlign.center,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: Colors.grey[600]),
                ),
                const SizedBox(height: 48),
                TextField(
                  controller: _manualIdController,
                  decoration: InputDecoration(
                    labelText: 'qr.id_label'.tr(),
                    hintText: 'qr.id_hint'.tr(),
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.fingerprint),
                    helperText: 'qr.id_helper'.tr(),
                    helperMaxLines: 2,
                  ),
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _handleManualId(),
                  enabled: !isProcessing,
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: isProcessing ? null : _handleManualId,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: isProcessing
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Text('qr.add_or_join'.tr()),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('qr.scan_title'.tr()),
        actions: [
          IconButton(
            icon: Icon(
              controller!.value.torchState == TorchState.on
                  ? Icons.flash_on
                  : Icons.flash_off,
            ),
            onPressed: () => controller!.toggleTorch(),
            tooltip: 'qr.toggle_flash'.tr(),
          ),
          IconButton(
            icon: const Icon(Icons.flip_camera_ios),
            onPressed: () => controller!.switchCamera(),
            tooltip: 'qr.switch_camera'.tr(),
          ),
          // Manual input button
          IconButton(
            icon: const Icon(Icons.keyboard),
            onPressed: () {
              setState(() {
                showManualInput = true;
              });
            },
            tooltip: 'qr.manual_input'.tr(),
          ),
          // Show my own QR code
          IconButton(
            icon: const Icon(Icons.qr_code),
            onPressed: () => _showMyQr(context),
            tooltip: 'settings.my_qr'.tr(),
          ),
        ],
      ),
      body: Stack(
        children: [
          // Scanner
          MobileScanner(controller: controller!, onDetect: _handleQrCode),

          // Overlay with instructions
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.8),
                    Colors.transparent,
                  ],
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.qr_code_scanner,
                    size: 48,
                    color: Colors.white.withValues(alpha: 0.8),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'qr.scan_instruction'.tr(),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Processing indicator
          if (isProcessing)
            Container(
              color: Colors.black54,
              child: const Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }
}
