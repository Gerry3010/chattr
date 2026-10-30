// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Total order over messages for display and pagination: **newest first** by
/// `createdAt`, then by message `id` as a deterministic tiebreak.
///
/// `createdAt` alone is not a unique key — sub-millisecond collisions happen,
/// and timestamps are mixed-source (own messages carry the sender's device
/// clock, received ones carry the server's `NOW()`), so two messages can share
/// (or skew past) a timestamp. Dart's `List.sort` and SQLite `ORDER BY` are not
/// stable, so without a tiebreak equal timestamps render in an arbitrary,
/// jittering order. Appending `id` makes the order a strict total order:
/// deterministic on every device and safe as a keyset-pagination boundary
/// (`messages_local_repository.dart` pages on the same `(created_at, id)` key).
///
/// Kept as free functions over primitives so the exact same ordering applies to
/// both the app's `MessageInterface` and chatview's `Message` (the render
/// layer's `messageSorter`).
int compareMessagesNewestFirst(
  DateTime aCreatedAt,
  String aId,
  DateTime bCreatedAt,
  String bId,
) {
  final byTime = bCreatedAt.compareTo(aCreatedAt);
  return byTime != 0 ? byTime : bId.compareTo(aId);
}

/// Whether message `a` is strictly **older** than message `b` under
/// [compareMessagesNewestFirst] (i.e. `a` sorts after `b` in newest-first
/// order). Used to find the oldest loaded message — the keyset cursor for the
/// next older page.
bool isOlderMessage(
  DateTime aCreatedAt,
  String aId,
  DateTime bCreatedAt,
  String bId,
) =>
    compareMessagesNewestFirst(aCreatedAt, aId, bCreatedAt, bId) > 0;
