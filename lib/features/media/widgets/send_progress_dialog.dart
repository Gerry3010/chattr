// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

/// Non-dismissible determinate "processing/sending" box shown while a big media
/// batch encrypts + uploads. Indeterminate until the first progress tick, then
/// fills the ring. Closed by the caller when the send ends. Shared by the
/// in-app attach flow ([sendMediaItems]) and the system-share flow so both show
/// the same feedback — large videos take a while to encrypt/chunk and without
/// this the app looks like it did nothing until the send finishes.
void showSendProgressDialog(
  BuildContext context,
  ValueNotifier<double> progress, {
  required bool isVideo,
  required VoidCallback onCancel,
}) {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    // Not dismissible by back/barrier — the X button is the only way out, and
    // it aborts the send (not just the dialog).
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        contentPadding: const EdgeInsets.fromLTRB(24, 20, 8, 20),
        content: ValueListenableBuilder<double>(
          valueListenable: progress,
          builder: (context, value, _) => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 44,
                height: 44,
                child: CircularProgressIndicator(
                  value: value <= 0 ? null : value.clamp(0.0, 1.0),
                ),
              ),
              const SizedBox(width: 20),
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      (isVideo ? 'media.processing_video' : 'media.sending').tr(),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    if (value > 0) ...[
                      const SizedBox(height: 4),
                      Text('${(value * 100).round()} %',
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ],
                ),
              ),
              // Abort the processing + send.
              IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'common.cancel'.tr(),
                onPressed: onCancel,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
