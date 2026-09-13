// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Turns what other apps hand us into the two envelopes (#70): a maps link or
/// `geo:` URI into a [LocationEnvelope], an iCalendar file into an
/// [EventEnvelope].
///
/// Pure functions over strings — no plugins, no network, so the whole thing is
/// unit-testable and cannot phone anybody while parsing. That matters here:
/// resolving a maps short link (`maps.app.goo.gl/…`) would mean asking Google
/// where the pin is, from the sender's device, at share time. We deliberately
/// do NOT do that; an unresolvable link stays an ordinary text message with its
/// link preview, which is what it was before this feature existed.
library;

import 'dart:convert' show LineSplitter;
import 'place_envelope.dart';

/// Extracts a pin from [text] if it plainly contains one.
///
/// "Plainly" is the whole design: we read coordinates that are already IN the
/// string. Nothing here guesses, geocodes or fetches. Returns null for anything
/// else — and null is a perfectly good answer, it just means "send it as text".
LocationEnvelope? parseSharedLocation(String? text) {
  final input = text?.trim();
  if (input == null || input.isEmpty) return null;

  // A share is often "Café Central\nhttps://maps.apple.com/?ll=48.2,16.3" —
  // the label rides on its own line. Take the first line that is not a URL as
  // the name, so the card is not left nameless.
  String? labelFrom(String s, String consumedUrl) {
    for (final line in s.split(RegExp(r'[\r\n]+'))) {
      final t = line.trim();
      if (t.isEmpty || t == consumedUrl) continue;
      if (t.startsWith('http://') ||
          t.startsWith('https://') ||
          t.startsWith('geo:')) {
        continue;
      }
      return t;
    }
    return null;
  }

  // ── geo: URI (Android's share format, and what our own card emits) ────────
  final geo = RegExp(
    r'geo:(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)(\?[^\s]*)?',
    caseSensitive: false,
  ).firstMatch(input);
  if (geo != null) {
    final lat = double.tryParse(geo.group(1)!);
    final lon = double.tryParse(geo.group(2)!);
    if (lat != null &&
        lon != null &&
        LocationEnvelope.isValidCoordinate(lat, lon)) {
      // `?q=lat,lon(Label)` carries the human name.
      String? name;
      final query = geo.group(3);
      if (query != null) {
        final labelled = RegExp(r'\(([^)]+)\)').firstMatch(query);
        if (labelled != null) name = Uri.decodeComponent(labelled.group(1)!);
      }
      return LocationEnvelope(
        latitude: lat,
        longitude: lon,
        name: name ?? labelFrom(input, geo.group(0)!),
      );
    }
  }

  // ── Map URLs that spell the coordinates out ──────────────────────────────
  // Covers what the common apps actually put on the clipboard:
  //   Apple  …/?ll=48.2,16.3   or   ?q=48.2,16.3
  //   Google …/@48.2,16.3,15z  ,  ?q=48.2,16.3  ,  !3d48.2!4d16.3
  //   OSM    …#map=15/48.2/16.3
  final url = RegExp(r'https?://[^\s]+', caseSensitive: false)
      .firstMatch(input)
      ?.group(0);
  if (url == null) return null;

  final patterns = <RegExp>[
    RegExp(r'[?&](?:ll|q|daddr|center)=(-?\d+\.\d+),(-?\d+\.\d+)'),
    RegExp(r'/@(-?\d+\.\d+),(-?\d+\.\d+)'),
    RegExp(r'!3d(-?\d+\.\d+)!4d(-?\d+\.\d+)'),
    RegExp(r'#map=\d+/(-?\d+\.\d+)/(-?\d+\.\d+)'),
  ];
  for (final p in patterns) {
    final m = p.firstMatch(url);
    if (m == null) continue;
    final lat = double.tryParse(m.group(1)!);
    final lon = double.tryParse(m.group(2)!);
    if (lat == null ||
        lon == null ||
        !LocationEnvelope.isValidCoordinate(lat, lon)) {
      continue;
    }
    return LocationEnvelope(
      latitude: lat,
      longitude: lon,
      name: labelFrom(input, url),
    );
  }
  return null;
}

/// Reads the FIRST VEVENT out of an iCalendar document.
///
/// A deliberately small reader, not a library: we want a title, a start, maybe
/// an end and a place. Everything else in the format — recurrence, alarms,
/// attendees, timezone definitions — is either irrelevant to a chat card or
/// something we specifically do not want to carry into a message.
///
/// Returns null on anything it does not confidently understand; the caller then
/// sends the file as a file, which is what happened before this existed.
EventEnvelope? parseIcs(String? source) {
  if (source == null || source.isEmpty) return null;
  if (!source.contains('BEGIN:VEVENT')) return null;

  // RFC 5545 folds long lines: a continuation starts with a space or tab and
  // belongs to the previous line. Unfold first or a long SUMMARY arrives cut
  // in half.
  final unfolded = source.replaceAll(RegExp(r'\r?\n[ \t]'), '');
  final lines = unfolded.split(RegExp(r'\r?\n'));

  var inEvent = false;
  String? title;
  String? location;
  DateTime? start;
  DateTime? end;
  var allDay = false;

  for (final raw in lines) {
    final line = raw.trim();
    if (line == 'BEGIN:VEVENT') {
      inEvent = true;
      continue;
    }
    if (line == 'END:VEVENT') break; // first event only
    if (!inEvent) continue;

    final colon = line.indexOf(':');
    if (colon <= 0) continue;
    final head = line.substring(0, colon);
    final value = line.substring(colon + 1);
    final property = head.split(';').first.toUpperCase();

    switch (property) {
      case 'SUMMARY':
        title = _unescapeIcsText(value);
      case 'LOCATION':
        location = _unescapeIcsText(value);
      case 'DTSTART':
        allDay = head.toUpperCase().contains('VALUE=DATE') &&
            !head.toUpperCase().contains('DATE-TIME');
        start = _parseIcsDate(value);
      case 'DTEND':
        end = _parseIcsDate(value);
    }
  }

  if (title == null || title.isEmpty || start == null) return null;
  return EventEnvelope(
    title: title,
    start: start,
    end: end,
    allDay: allDay,
    location: location,
  );
}

/// `20260814T190000Z`, `20260814T190000` (local — read as UTC, see below) or
/// `20260814` (all-day).
///
/// A floating (no-Z) time is treated as UTC on purpose. The alternative would
/// be to guess the sender's timezone from a VTIMEZONE block we do not parse;
/// reading it as UTC is at least a stated rule, and the overwhelmingly common
/// real-world case — an export from a phone calendar — carries the Z.
DateTime? _parseIcsDate(String value) {
  final v = value.trim();
  final withTime = RegExp(r'^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})(Z?)$')
      .firstMatch(v);
  if (withTime != null) {
    return DateTime.utc(
      int.parse(withTime.group(1)!),
      int.parse(withTime.group(2)!),
      int.parse(withTime.group(3)!),
      int.parse(withTime.group(4)!),
      int.parse(withTime.group(5)!),
      int.parse(withTime.group(6)!),
    );
  }
  final dateOnly = RegExp(r'^(\d{4})(\d{2})(\d{2})$').firstMatch(v);
  if (dateOnly != null) {
    return DateTime.utc(
      int.parse(dateOnly.group(1)!),
      int.parse(dateOnly.group(2)!),
      int.parse(dateOnly.group(3)!),
    );
  }
  return null;
}

/// RFC 5545 escaping: `\,` `\;` `\\` and `\n` for a line break.
String _unescapeIcsText(String value) {
  final out = StringBuffer();
  for (var i = 0; i < value.length; i++) {
    final c = value[i];
    if (c != r'\' || i + 1 >= value.length) {
      out.write(c);
      continue;
    }
    final next = value[i + 1];
    i++;
    switch (next) {
      case 'n':
      case 'N':
        out.write('\n');
      case r'\':
        out.write(r'\');
      case ',':
        out.write(',');
      case ';':
        out.write(';');
      default:
        out.write(next);
    }
  }
  return out.toString().trim();
}

/// A finished envelope that the platform handed us verbatim, or null.
///
/// The iOS share extension reads an Apple Maps place natively and emits
/// `_chattr_location` as the shared TEXT (share_handler fork p1) — it has the
/// name and address right there, which no link would carry. Two things go
/// wrong without this:
///
/// * `parseSharedLocation` does not recognise our own envelope (it looks for
///   map links), so the share would fall through to the plain-text edit sheet
///   and show the user raw JSON before sending.
/// * Apple often attaches the place AND a `maps.apple.com` link; the extension
///   joins shared texts with a newline, so the whole thing stops being valid
///   JSON and we would fall back to parsing the link — throwing away exactly
///   the name and address the native read was for.
///
/// Hence: scan line by line and take the first line that already is one of
/// ours.
String? verbatimPlaceEnvelope(String? sharedText) {
  if (sharedText == null || sharedText.isEmpty) return null;
  for (final line in const LineSplitter().convert(sharedText)) {
    final candidate = line.trim();
    if (candidate.isEmpty || !candidate.startsWith('{')) continue;
    final location = LocationEnvelope.tryParse(candidate);
    if (location != null) return location.encode();
    final event = EventEnvelope.tryParse(candidate);
    if (event != null) return event.encode();
  }
  return null;
}
