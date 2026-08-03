// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../features/auth/auth_controller.dart';
import '../../features/identity/identity_verification_controller.dart';
import '../../features/identity/identity_verification_repository.dart';
import '../../features/profiles/profile_helpers.dart';

class QrDisplayScreen extends ConsumerWidget {
  const QrDisplayScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userId = ref.watch(authControllerProvider);
    final username = ref.watch(usernameProvider(userId ?? ''));

    if (userId == null) {
      return Scaffold(
        appBar: AppBar(
          title: Text('qr.my_code_title'.tr()),
        ),
        body: Center(
          child: Text('qr.not_logged_in'.tr()),
        ),
      );
    }

    // Create QR Code data. When the identity key is ready, embed it (`ik`, v2)
    // so a scanner can pin it (TOFU) and verify this user's keys/messages
    // against it (audit C1). Older scanners ignore the extra fields; if the key
    // isn't ready yet the code is a plain v1 (still valid, just unverifiable).
    final identityKey = ref.watch(myIdentityPublicKeyProvider).asData?.value;
    // Best-effort (re)publish of that key to `profiles` — a device whose
    // startup publish failed would otherwise hand out a QR whose `ik` no peer
    // can ever match against the server. Idempotent, result only logged.
    ref.watch(identityPublishRetryProvider);
    final qrPayload = <String, Object>{
      'type': 'chattr_user',
      'user_id': userId,
    };
    if (identityKey != null) {
      qrPayload['v'] = 2;
      qrPayload['ik'] = identityKey;
    }
    final qrData = jsonEncode(qrPayload);

    return Scaffold(
      appBar: AppBar(
        title: Text('qr.my_code_title'.tr()),
        actions: [
          IconButton(
            icon: const Icon(Icons.share),
            onPressed: () {
              SharePlus.instance.share(ShareParams(
                text: userId,
                subject: 'qr.share_subject'.tr(),
              ));
            },
            tooltip: 'qr.share_id'.tr(),
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Username
              Text(
                username,
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                'qr.share_instruction'.tr(),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.grey[600],
                    ),
              ),
              const SizedBox(height: 48),

              // QR Code
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.1),
                      blurRadius: 20,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: QrImageView(
                  data: qrData,
                  version: QrVersions.auto,
                  size: 280,
                  backgroundColor: Colors.white,
                  eyeStyle: const QrEyeStyle(
                    eyeShape: QrEyeShape.square,
                    color: Colors.black,
                  ),
                  dataModuleStyle: const QrDataModuleStyle(
                    dataModuleShape: QrDataModuleShape.square,
                    color: Colors.black,
                  ),
                ),
              ),
              const SizedBox(height: 48),

              // User ID (full, selectable)
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.fingerprint,
                          size: 20,
                          color: Colors.grey[700],
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'qr.your_id'.tr(),
                          style: TextStyle(
                            fontWeight: FontWeight.w500,
                            color: Colors.grey[700],
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          icon: const Icon(Icons.copy, size: 18),
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: userId));
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('qr.id_copied'.tr()),
                                duration: const Duration(seconds: 2),
                              ),
                            );
                          },
                          tooltip: 'qr.copy_id'.tr(),
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 32,
                            minHeight: 32,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    IntrinsicWidth(
                      child: SelectableText(
                        userId,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          color: Colors.grey[700],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Info Text
              Text(
                'qr.privacy_note'.tr(),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.grey[600],
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
