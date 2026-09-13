// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'in_app_notification_service.dart';
import 'notification_provider.dart';
import 'notification_sound.dart';
import '../../features/chats/chat_sound_controller.dart';

/// Overlay widget that displays in-app notifications at the top of the screen
class InAppNotificationOverlay extends ConsumerStatefulWidget {
  final Widget child;

  const InAppNotificationOverlay({
    super.key,
    required this.child,
  });

  @override
  ConsumerState<InAppNotificationOverlay> createState() =>
      _InAppNotificationOverlayState();
}

class _InAppNotificationOverlayState
    extends ConsumerState<InAppNotificationOverlay> {
  final List<_NotificationEntry> _notifications = [];
  StreamSubscription<InAppNotification>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscribeToNotifications();
  }

  void _subscribeToNotifications() {
    final notificationService = ref.read(inAppNotificationServiceProvider);
    _subscription = notificationService.notifications.listen((notification) {
      _showNotification(notification);
    });
  }

  /// Audible + haptic cue for incoming social notifications (not for
  /// self-triggered info/error toasts). Best-effort — never let a missing
  /// audio/haptic plugin break the banner.
  void _alert(NotificationType type, String? chatId) {
    const audible = {
      NotificationType.newMessage,
      NotificationType.memberRequest,
      NotificationType.memberAccepted,
    };
    if (!audible.contains(type)) return;
    // This chat's sound, otherwise the general one — the resolution lives in
    // ONE function, so no caller forgets the fallback.
    final sound = soundForChat(ref, chatId);
    if (sound.asset != null) {
      NotificationSound.instance.play(sound.asset!);
    }
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.android)) {
      HapticFeedback.mediumImpact();
    }
  }

  void _showNotification(InAppNotification notification) {
    _alert(notification.type, notification.chatId);
    final entry = _NotificationEntry(
      notification: notification,
      onDismiss: () {
        setState(() {
          _notifications.removeWhere((e) => e.notification.id == notification.id);
        });
      },
    );

    setState(() {
      _notifications.add(entry);
    });

    // Auto-dismiss after duration
    if (notification.duration != null) {
      Future.delayed(notification.duration!, () {
        if (mounted) {
          entry.onDismiss();
        }
      });
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        // Notification banners
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            child: Column(
              children: _notifications.map((entry) {
                return _NotificationBanner(
                  notification: entry.notification,
                  onDismiss: entry.onDismiss,
                );
              }).toList(),
            ),
          ),
        ),
      ],
    );
  }
}

class _NotificationEntry {
  final InAppNotification notification;
  final VoidCallback onDismiss;

  _NotificationEntry({
    required this.notification,
    required this.onDismiss,
  });
}

/// Individual notification banner widget
class _NotificationBanner extends StatefulWidget {
  final InAppNotification notification;
  final VoidCallback onDismiss;

  const _NotificationBanner({
    required this.notification,
    required this.onDismiss,
  });

  @override
  State<_NotificationBanner> createState() => _NotificationBannerState();
}

class _NotificationBannerState extends State<_NotificationBanner>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<Offset> _slideAnimation;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );

    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, -1),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    ));

    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeIn,
    ));

    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _dismiss() async {
    await _controller.reverse();
    widget.onDismiss();
  }

  @override
  Widget build(BuildContext context) {
    return SlideTransition(
      position: _slideAnimation,
      child: FadeTransition(
        opacity: _fadeAnimation,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              onTap: () {
                widget.notification.onTap?.call();
                _dismiss();
              },
              borderRadius: BorderRadius.circular(12),
              child: Container(
                decoration: BoxDecoration(
                  color: widget.notification.color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: widget.notification.color.withValues(alpha: 0.3),
                    width: 1,
                  ),
                ),
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    // Icon
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: widget.notification.color.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        widget.notification.icon,
                        color: widget.notification.color,
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 12),
                    // Content
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.notification.title,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            widget.notification.message,
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey[700],
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    // Dismiss button
                    IconButton(
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: _dismiss,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
