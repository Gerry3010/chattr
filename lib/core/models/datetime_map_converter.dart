// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:json_annotation/json_annotation.dart';

/// (De)serializes `Map<String, DateTime?>` (e.g. per-recipient received/read
/// timestamps) as a JSON object of ISO-8601 strings (or null).
///
/// **Defensive on read.** The server stores `received_at`/`read_at` as *scalar*
/// timestamps (one DB row per recipient), not a map — so a freshly fetched
/// message has a plain string there, while a message round-tripped through the
/// local store has a map. Any non-map value (scalar string, null, absent)
/// therefore decodes to an empty map, matching the original hand-written parser
/// that only populated the map when the value was actually a `Map`.
///
/// The source type is `Object?` (not `Map<String, dynamic>?`) on purpose: it
/// makes json_serializable emit a safe `as Object?` cast instead of one that
/// throws with "String is not a subtype of Map" on server payloads.
class DateTimeMapConverter
    implements JsonConverter<Map<String, DateTime?>, Object?> {
  const DateTimeMapConverter();

  @override
  Map<String, DateTime?> fromJson(Object? json) {
    if (json is! Map) return {};
    return json.map(
      (key, value) => MapEntry(
        key as String,
        value == null ? null : DateTime.parse(value as String),
      ),
    );
  }

  @override
  Object? toJson(Map<String, DateTime?> object) =>
      object.map((key, value) => MapEntry(key, value?.toIso8601String()));
}
