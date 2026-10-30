// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Wire formats for the two "shared marker" message kinds (#70):
/// `_chattr_location` (a pin) and `_chattr_event` (a calendar entry).
///
/// **Hard product boundary, set by Gerry: a location message is a MARKER, never
/// a position.** There is no "my current location", no live sharing, no
/// continuous tracking — and nothing in this file can express one. A
/// [LocationEnvelope] is a place somebody deliberately picked and sent once,
/// exactly like sending an address in text, and it carries no timestamp,
/// accuracy or heading that would let a receiver reconstruct movement. Keep it
/// that way: the moment an envelope grows a "sent at this position" field, the
/// promise on the landing page stops being true.
///
/// Both ride inside an ordinary E2E-encrypted message body, like
/// `_chattr_invite` and the media album — the server sees ciphertext and
/// nothing else.
library;

import 'dart:convert';

/// A pin somebody shared: coordinates plus whatever they were labelled with.
class LocationEnvelope {
  static const String marker = '_chattr_location';

  final double latitude;
  final double longitude;

  /// What the sender's map called the place ("Café Central"), when it said so.
  final String? name;

  /// A street address, when the source carried one.
  final String? address;

  /// A line the sender wrote alongside the pin ("20:30 dort?").
  ///
  /// Deliberately part of the message, not a second one: a comment that can
  /// arrive without its place — or a place whose comment scrolled away — is
  /// worse than no comment. The boundary from the class doc still holds; a
  /// note is prose the sender typed, never anything the device measured.
  final String? note;

  const LocationEnvelope({
    required this.latitude,
    required this.longitude,
    this.name,
    this.address,
    this.note,
  });

  LocationEnvelope withNote(String? note) => LocationEnvelope(
        latitude: latitude,
        longitude: longitude,
        name: name,
        address: address,
        note: note == null || note.isEmpty ? null : note,
      );

  /// Latitude/longitude in the ranges WGS 84 actually defines. Anything else is
  /// a parse accident, and a card silently pointing at the wrong hemisphere is
  /// worse than no card.
  static bool isValidCoordinate(double lat, double lon) =>
      lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180;

  String encode() => jsonEncode({
        marker: 1,
        'lat': latitude,
        'lon': longitude,
        if (name != null && name!.isNotEmpty) 'name': name,
        if (address != null && address!.isNotEmpty) 'address': address,
        if (note != null && note!.isNotEmpty) 'note': note,
      });

  static LocationEnvelope? tryParse(String? body) {
    if (body == null || body.isEmpty || !body.contains(marker)) return null;
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      if (json[marker] == null) return null;
      final lat = (json['lat'] as num?)?.toDouble();
      final lon = (json['lon'] as num?)?.toDouble();
      if (lat == null || lon == null || !isValidCoordinate(lat, lon)) {
        return null;
      }
      final name = json['name'];
      final address = json['address'];
      final note = json['note'];
      return LocationEnvelope(
        latitude: lat,
        longitude: lon,
        name: name is String && name.isNotEmpty ? name : null,
        address: address is String && address.isNotEmpty ? address : null,
        note: note is String && note.isNotEmpty ? note : null,
      );
    } catch (_) {
      return null;
    }
  }

  /// A `geo:` URI — the neutral way to hand a pin to whatever map app the
  /// receiver actually uses. `q=` repeats the coordinates with the label so
  /// Android's chooser shows a named marker instead of a bare dot.
  ///
  /// **Android and desktop only.** iOS does not register `geo:` at all — see
  /// [openUris].
  String toGeoUri() {
    final coords = '$latitude,$longitude';
    final label = name ?? address;
    if (label == null || label.isEmpty) return 'geo:$coords';
    return 'geo:$coords?q=$coords(${Uri.encodeComponent(label)})';
  }

  /// Apple's own scheme. `ll` places the pin, `q` names it.
  String toAppleMapsUri() {
    final coords = '$latitude,$longitude';
    final label = name ?? address;
    final query = label == null || label.isEmpty
        ? ''
        : '&q=${Uri.encodeComponent(label)}';
    return 'maps://?ll=$coords$query';
  }

  /// A last resort that needs no app at all.
  String toOpenStreetMapUri() =>
      'https://www.openstreetmap.org/?mlat=$latitude&mlon=$longitude'
      '#map=17/$latitude/$longitude';

  /// Where to send a tap, best first.
  ///
  /// The order is the whole point: hand the pin to the map app the receiver
  /// already uses, and only fall back to a website when no app claims it.
  ///
  /// On **iOS** `geo:` must not come first — the system does not register that
  /// scheme, so the attempt fails and the pin ends up on the OpenStreetMap
  /// *website* instead of in Maps. (Reported 2026-08-13; the old code assumed
  /// iOS merely ignored the extra parameters.) `maps://` goes first there;
  /// `geo:` still follows, because an installed third-party map app may claim
  /// it and that is closer to "the user's own app" than a website.
  ///
  /// Everywhere else `geo:` leads: on Android it opens the chooser the user
  /// configured, which is exactly the intent.
  List<String> openUris({required bool isApple}) => isApple
      ? [toAppleMapsUri(), toGeoUri(), toOpenStreetMapUri()]
      : [toGeoUri(), toOpenStreetMapUri()];
}

/// A calendar entry somebody shared. Deliberately a handful of display fields,
/// not a re-encoded iCalendar: the card shows what it says, and re-emitting a
/// full VEVENT would invite treating this as a calendar sync it is not.
class EventEnvelope {
  static const String marker = '_chattr_event';

  final String title;

  /// Start instant. Always stored UTC; an all-day entry uses midnight UTC and
  /// leans on [allDay] rather than on a timezone-free date string, so the two
  /// cases cannot be confused after a round trip.
  final DateTime start;

  /// End instant, when the source gave one.
  final DateTime? end;

  /// A date without a time of day. Rendered without one too — showing "00:00"
  /// for a birthday is how all-day entries usually go wrong.
  final bool allDay;

  final String? location;

  /// A line the sender wrote alongside the entry. See [LocationEnvelope.note].
  final String? note;

  const EventEnvelope({
    required this.title,
    required this.start,
    this.end,
    this.allDay = false,
    this.location,
    this.note,
  });

  EventEnvelope withNote(String? note) => EventEnvelope(
        title: title,
        start: start,
        end: end,
        allDay: allDay,
        location: location,
        note: note == null || note.isEmpty ? null : note,
      );

  String encode() => jsonEncode({
        marker: 1,
        'title': title,
        'start': start.toUtc().toIso8601String(),
        if (end != null) 'end': end!.toUtc().toIso8601String(),
        if (allDay) 'all_day': true,
        if (location != null && location!.isNotEmpty) 'location': location,
        if (note != null && note!.isNotEmpty) 'note': note,
      });

  static EventEnvelope? tryParse(String? body) {
    if (body == null || body.isEmpty || !body.contains(marker)) return null;
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      if (json[marker] == null) return null;
      final title = json['title'];
      final start = json['start'];
      if (title is! String || title.isEmpty || start is! String) return null;
      final startAt = DateTime.tryParse(start);
      if (startAt == null) return null;
      final rawEnd = json['end'];
      final location = json['location'];
      final note = json['note'];
      return EventEnvelope(
        title: title,
        start: startAt.toUtc(),
        end: rawEnd is String ? DateTime.tryParse(rawEnd)?.toUtc() : null,
        allDay: json['all_day'] == true,
        location: location is String && location.isNotEmpty ? location : null,
        note: note is String && note.isNotEmpty ? note : null,
      );
    } catch (_) {
      return null;
    }
  }
}
