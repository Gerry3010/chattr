// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:url_launcher/url_launcher.dart';

import '../../../core/logging/logger_service.dart';
import '../../../core/utils/app_time.dart';
import '../../../features/places/place_envelope.dart';

/// Shared chrome for the two marker cards (#70) — same width, radius, border
/// and on-card colour rules as [InviteMessageCard], because they sit in the
/// same bubble column and a second visual language there just reads as a bug.
///
/// Every colour is derived from the card's OWN background: the card paints
/// itself `primaryContainer` (own) or `surfaceContainerHighest` (received), so
/// the text has to come from the matching `on…` role. Inheriting the bubble's
/// colour is exactly what made the invite card unreadable in the forest theme.
class _PlaceCard extends StatelessWidget {
  final bool isOwn;
  final IconData icon;
  final String title;
  final String? subtitle;

  /// Extra lines under the subtitle (date range, address).
  final List<String> details;

  /// Label + action of the single button, or null for a card without one.
  final String? actionLabel;
  final VoidCallback? onAction;

  /// What the sender wrote alongside — set apart from the place's own details
  /// so it reads as their words, not as another field the map supplied.
  final String? note;

  const _PlaceCard({
    required this.isOwn,
    required this.icon,
    required this.title,
    this.subtitle,
    this.details = const [],
    this.actionLabel,
    this.onAction,
    this.note,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final onCard = isOwn ? scheme.onPrimaryContainer : scheme.onSurface;
    // 0.85 rather than the habitual 0.7 — below that the muted lines drop under
    // WCAG AA on the lighter palettes. Same reasoning (and same test) as the
    // invitation card.
    final onCardMuted = onCard.withValues(alpha: 0.85);

    return Container(
      constraints: const BoxConstraints(maxWidth: 280),
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isOwn ? scheme.primaryContainer : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                backgroundColor: scheme.primary,
                foregroundColor: scheme.onPrimary,
                child: Icon(icon),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: onCard,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (subtitle != null && subtitle!.isNotEmpty)
                      Text(
                        subtitle!,
                        style: TextStyle(fontSize: 12, color: onCardMuted),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    for (final line in details)
                      Text(
                        line,
                        style: TextStyle(fontSize: 12, color: onCardMuted),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (note != null && note!.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              note!,
              style: TextStyle(color: onCard),
            ),
          ],
          if (actionLabel != null) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: onAction,
                style: OutlinedButton.styleFrom(
                  foregroundColor: onCard,
                  side: BorderSide(color: onCard.withValues(alpha: 0.45)),
                ),
                child: Text(actionLabel!),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A shared pin.
///
/// **Draws no map.** A tile from any map service would be fetched at render
/// time by every recipient, handing that service the coordinates and each
/// viewer's IP — turning a message the server cannot read into a request a
/// third party can. So the card shows what it knows (label, address,
/// coordinates) and hands off to the platform's own map app on tap, where the
/// user has already decided who they talk to.
class LocationMessageCard extends StatelessWidget {
  final LocationEnvelope location;
  final bool isOwn;

  const LocationMessageCard({
    super.key,
    required this.location,
    required this.isOwn,
  });

  static String formatCoordinates(LocationEnvelope l) =>
      '${l.latitude.toStringAsFixed(5)}, ${l.longitude.toStringAsFixed(5)}';

  Future<void> _open(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final isApple = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS);
    try {
      // Try each handoff in turn and stop at the first that a app takes. A
      // failed attempt must not be the end: on iOS `geo:` simply is not
      // registered, and treating that as "done" is what put shared pins on the
      // OpenStreetMap website instead of into Maps.
      for (final candidate in location.openUris(isApple: isApple)) {
        final uri = Uri.parse(candidate);
        try {
          if (await launchUrl(uri, mode: LaunchMode.externalApplication)) {
            return;
          }
        } on PlatformException catch (e) {
          // An unregistered scheme throws here rather than returning false.
          logger.debug('No handler for $candidate: $e', tag: 'Places');
        }
      }
      throw StateError('no map handler took the pin');
    } catch (e) {
      logger.warning('Could not open the shared location: $e', tag: 'Places');
      messenger?.showSnackBar(
        SnackBar(content: Text('places.open_failed'.tr())),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final coordinates = formatCoordinates(location);
    return _PlaceCard(
      isOwn: isOwn,
      icon: Icons.place_outlined,
      title: location.name ?? location.address ?? 'places.location'.tr(),
      // Never repeat the line already used as the title.
      subtitle: location.name != null ? location.address : null,
      details: [coordinates],
      note: location.note,
      actionLabel: 'places.open_in_maps'.tr(),
      onAction: () => _open(context),
    );
  }
}

/// A shared calendar entry. Read-only on purpose: it says what was shared, it
/// does not write to anybody's calendar.
class EventMessageCard extends StatelessWidget {
  final EventEnvelope event;
  final bool isOwn;

  const EventMessageCard({
    super.key,
    required this.event,
    required this.isOwn,
  });

  /// "14.8.2026" for an all-day entry, "14.8.2026 19:00–21:00" when it has
  /// times, and the end date spelled out when it falls on another day.
  ///
  /// An all-day entry never shows a time. Its instant is midnight UTC, so
  /// printing one would mean inventing a precision the source did not have —
  /// and on the wrong side of a timezone it prints the previous evening.
  static String formatWhen(EventEnvelope event, String locale) {
    if (event.allDay) {
      final start = AppTime.ymd(event.start, locale);
      final end = event.end;
      if (end == null) return start;
      // An all-day DTEND is exclusive (RFC 5545): a one-day entry ends on the
      // NEXT day. Showing that raw would claim the party lasts into tomorrow.
      final lastDay = end.subtract(const Duration(days: 1));
      if (!lastDay.isAfter(event.start)) return start;
      return '$start – ${AppTime.ymd(lastDay, locale)}';
    }
    final start = AppTime.ymdHm(event.start, locale);
    final end = event.end;
    if (end == null) return start;
    final sameDay = event.start.toLocal().year == end.toLocal().year &&
        event.start.toLocal().month == end.toLocal().month &&
        event.start.toLocal().day == end.toLocal().day;
    return sameDay
        ? '$start – ${AppTime.hm(end, locale)}'
        : '$start – ${AppTime.ymdHm(end, locale)}';
  }

  @override
  Widget build(BuildContext context) {
    final locale = context.locale.toString();
    return _PlaceCard(
      isOwn: isOwn,
      icon: Icons.event_outlined,
      title: event.title,
      subtitle: formatWhen(event, locale),
      details: [if (event.location != null) event.location!],
      note: event.note,
    );
  }
}
