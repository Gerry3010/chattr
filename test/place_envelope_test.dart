// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Sharing markers and calendar entries (#70).
//
// The hard product boundary Gerry set is "a marker, never a position": no
// current location, no live sharing. That is enforced by what the envelope can
// hold, so the tests pin the shape as much as the parsing — an envelope that
// grew a timestamp or an accuracy would break these.
//
// The parsers are deliberately incapable of resolving anything: a short link
// would have to be handed to Google from the sender's device to learn where it
// points, so an unrecognised link stays ordinary text.
//
//   flutter test test/place_envelope_test.dart

import 'package:chattr/features/places/place_envelope.dart';
import 'package:chattr/features/places/place_parsers.dart';
import 'package:chattr/features/places/place_preview_label.dart';
import 'package:chattr/screens/chat/components/place_message_cards.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  // AppTime formats through intl; without the locale data every date line
  // throws instead of formatting.
  setUpAll(() async => initializeDateFormatting());

  group('LocationEnvelope', () {
    test('survives a round trip with its label', () {
      const original = LocationEnvelope(
        latitude: 48.2082,
        longitude: 16.3738,
        name: 'Stephansdom',
        address: 'Stephansplatz 3, 1010 Wien',
      );
      final back = LocationEnvelope.tryParse(original.encode())!;
      expect(back.latitude, 48.2082);
      expect(back.longitude, 16.3738);
      expect(back.name, 'Stephansdom');
      expect(back.address, 'Stephansplatz 3, 1010 Wien');
    });

    test('a bare pin needs no label', () {
      const bare = LocationEnvelope(latitude: -33.8688, longitude: 151.2093);
      final back = LocationEnvelope.tryParse(bare.encode())!;
      expect(back.name, isNull);
      expect(back.address, isNull);
      expect(back.longitude, 151.2093);
    });

    test('impossible coordinates are refused, not shown', () {
      // A card pointing confidently at the wrong hemisphere is worse than no
      // card, so an out-of-range value fails the parse instead of clamping.
      expect(
        LocationEnvelope.tryParse('{"_chattr_location":1,"lat":91,"lon":0}'),
        isNull,
      );
      expect(
        LocationEnvelope.tryParse('{"_chattr_location":1,"lat":0,"lon":181}'),
        isNull,
      );
      expect(
        LocationEnvelope.tryParse('{"_chattr_location":1,"lat":"x","lon":0}'),
        isNull,
      );
    });

    test('anything that is not our envelope parses to null', () {
      expect(LocationEnvelope.tryParse('hallo'), isNull);
      expect(LocationEnvelope.tryParse('{"_chattr_invite":1}'), isNull);
      expect(LocationEnvelope.tryParse(null), isNull);
      expect(LocationEnvelope.tryParse('{"_chattr_location":1}'), isNull);
    });

    test('the geo: URI carries the label for the receiver\'s map app', () {
      const pin = LocationEnvelope(
        latitude: 48.2,
        longitude: 16.37,
        name: 'Café Central',
      );
      expect(pin.toGeoUri(), 'geo:48.2,16.37?q=48.2,16.37(Caf%C3%A9%20Central)');
      const unnamed = LocationEnvelope(latitude: 48.2, longitude: 16.37);
      expect(unnamed.toGeoUri(), 'geo:48.2,16.37');
    });
  });

  group('parseSharedLocation', () {
    test('reads a geo: URI, label included', () {
      final pin = parseSharedLocation('geo:48.2,16.37?q=48.2,16.37(Oper)')!;
      expect(pin.latitude, 48.2);
      expect(pin.name, 'Oper');
    });

    test('reads the coordinate forms the common map apps actually share', () {
      final cases = {
        'https://maps.apple.com/?ll=48.2082,16.3738&q=Stephansdom': 48.2082,
        'https://www.google.com/maps/@48.2082,16.3738,15z': 48.2082,
        'https://www.google.com/maps?q=48.2082,16.3738': 48.2082,
        'https://www.google.com/maps/place/X/data=!3d48.2082!4d16.3738': 48.2082,
        'https://www.openstreetmap.org/#map=15/48.2082/16.3738': 48.2082,
      };
      cases.forEach((url, lat) {
        final pin = parseSharedLocation(url);
        expect(pin, isNotNull, reason: url);
        expect(pin!.latitude, lat, reason: url);
        expect(pin.longitude, 16.3738, reason: url);
      });
    });

    test('picks up a label shared on its own line', () {
      final pin = parseSharedLocation(
        'Café Central\nhttps://maps.apple.com/?ll=48.2,16.37',
      )!;
      expect(pin.name, 'Café Central');
    });

    test('a link it cannot read stays text — it is never resolved', () {
      // Following a short link would mean asking Google where the pin is, from
      // the sender's device. Null here means "send it as an ordinary message",
      // which is the behaviour that existed before the feature.
      expect(parseSharedLocation('https://maps.app.goo.gl/abc123'), isNull);
      expect(parseSharedLocation('https://example.org'), isNull);
      expect(parseSharedLocation('schau mal hier'), isNull);
      expect(parseSharedLocation(''), isNull);
      expect(parseSharedLocation(null), isNull);
    });

    test('an out-of-range coordinate in a URL is not accepted', () {
      expect(parseSharedLocation('https://maps.apple.com/?ll=99.9,16.37'),
          isNull);
    });
  });

  group('parseIcs', () {
    const ics = '''
BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
UID:1@example.org
SUMMARY:Abendessen mit Sebi
DTSTART:20260814T190000Z
DTEND:20260814T210000Z
LOCATION:Café Central\\, Wien
END:VEVENT
END:VCALENDAR
''';

    test('reads title, start, end and place', () {
      final event = parseIcs(ics)!;
      expect(event.title, 'Abendessen mit Sebi');
      expect(event.start, DateTime.utc(2026, 8, 14, 19));
      expect(event.end, DateTime.utc(2026, 8, 14, 21));
      expect(event.location, 'Café Central, Wien'); // escaped comma resolved
      expect(event.allDay, isFalse);
    });

    test('an all-day entry is marked as one, not given a midnight time', () {
      final event = parseIcs('''
BEGIN:VEVENT
SUMMARY:Geburtstag
DTSTART;VALUE=DATE:20260814
END:VEVENT
''')!;
      expect(event.allDay, isTrue);
      expect(event.start, DateTime.utc(2026, 8, 14));
      expect(event.end, isNull);
    });

    test('a folded long title is put back together', () {
      // RFC 5545 wraps long lines; without unfolding the title arrives cut in
      // half — and it looks like a truncation bug, not a parser one.
      //
      // Unfolding removes the line break plus EXACTLY ONE following whitespace
      // character (that one is the fold marker). The second space below is a
      // real word space and has to survive — dropping it would silently glue
      // two words together in every wrapped title.
      final event = parseIcs('''
BEGIN:VEVENT
SUMMARY:Ein sehr langer Titel der über
  zwei Zeilen gefaltet wurde
DTSTART:20260814T190000Z
END:VEVENT
''')!;
      expect(
        event.title,
        'Ein sehr langer Titel der über zwei Zeilen gefaltet wurde',
      );
    });

    test('only the FIRST event is read', () {
      final event = parseIcs('''
BEGIN:VEVENT
SUMMARY:Erster
DTSTART:20260814T190000Z
END:VEVENT
BEGIN:VEVENT
SUMMARY:Zweiter
DTSTART:20260901T090000Z
END:VEVENT
''')!;
      expect(event.title, 'Erster');
    });

    test('anything incomplete or unrelated stays a file', () {
      expect(parseIcs('nicht mal ansatzweise ics'), isNull);
      expect(parseIcs(null), isNull);
      // No SUMMARY → nothing to put on a card.
      expect(parseIcs('BEGIN:VEVENT\nDTSTART:20260814T190000Z\nEND:VEVENT'),
          isNull);
      // No DTSTART → likewise.
      expect(parseIcs('BEGIN:VEVENT\nSUMMARY:Ohne Datum\nEND:VEVENT'), isNull);
    });

    test('the parsed event survives the envelope round trip', () {
      final original = parseIcs(ics)!;
      final back = EventEnvelope.tryParse(original.encode())!;
      expect(back.title, original.title);
      expect(back.start, original.start);
      expect(back.end, original.end);
      expect(back.location, original.location);
      expect(back.allDay, original.allDay);
    });

    test('all-day survives the round trip as all-day', () {
      // The trap this guards: storing an all-day entry as plain midnight and
      // losing the flag makes every birthday render as "00:00".
      final allDay = EventEnvelope(
        title: 'Geburtstag',
        start: DateTime.utc(2026, 8, 14),
        allDay: true,
      );
      expect(EventEnvelope.tryParse(allDay.encode())!.allDay, isTrue);
    });
  });

  group('the boundary: a marker, never a position', () {
    test('a location envelope carries no time and no accuracy', () {
      // Enforced by the wire format itself: whatever the sender's device knows
      // about when or how precisely it stood somewhere cannot be encoded, so a
      // receiver can never reconstruct movement from a series of these.
      final json = const LocationEnvelope(latitude: 1, longitude: 2).encode();
      for (final forbidden in [
        'time',
        'timestamp',
        'accuracy',
        'speed',
        'heading',
        'altitude',
      ]) {
        expect(json.contains(forbidden), isFalse,
            reason: '$forbidden must not be expressible');
      }
    });
  });

  group('EventMessageCard.formatWhen', () {
    // The card's date line is where an all-day entry usually goes wrong.
    test('an all-day entry shows no time of day', () {
      final event = EventEnvelope(
        title: 'Geburtstag',
        start: DateTime.utc(2026, 8, 14),
        allDay: true,
      );
      final line = EventMessageCard.formatWhen(event, 'de');
      expect(line.contains(':'), isFalse,
          reason: 'midnight UTC is not a time the source ever stated');
    });

    test('a one-day all-day entry is not stretched into the next day', () {
      // RFC 5545 makes an all-day DTEND EXCLUSIVE: a single day ends on the
      // following date. Printing that raw claims the party runs into tomorrow.
      final event = EventEnvelope(
        title: 'Feiertag',
        start: DateTime.utc(2026, 8, 14),
        end: DateTime.utc(2026, 8, 15),
        allDay: true,
      );
      expect(EventMessageCard.formatWhen(event, 'de'), contains('14'));
      expect(EventMessageCard.formatWhen(event, 'de').contains('–'), isFalse);
    });

    test('a multi-day all-day entry names the LAST day, not the day after', () {
      final event = EventEnvelope(
        title: 'Urlaub',
        start: DateTime.utc(2026, 8, 14),
        end: DateTime.utc(2026, 8, 17), // exclusive → runs through the 16th
        allDay: true,
      );
      final line = EventMessageCard.formatWhen(event, 'de');
      expect(line, contains('16'));
      expect(line.contains('17'), isFalse);
    });

    test('a timed entry on one day shows only the end time', () {
      final event = EventEnvelope(
        title: 'Abendessen',
        start: DateTime.utc(2026, 8, 14, 17),
        end: DateTime.utc(2026, 8, 14, 19),
      );
      expect(EventMessageCard.formatWhen(event, 'de'), contains('–'));
    });

    test('an entry without an end shows just the start', () {
      final event = EventEnvelope(
        title: 'Offen',
        start: DateTime.utc(2026, 8, 14, 17),
      );
      expect(EventMessageCard.formatWhen(event, 'de').contains('–'), isFalse);
    });
  });

  group('placePreviewLabel — no raw JSON anywhere', () {
    test('a named pin is named', () {
      const pin = LocationEnvelope(
        latitude: 48.2,
        longitude: 16.37,
        name: 'Café Central',
      );
      expect(placePreviewLabel(pin.encode()), '\u{1F4CD} Café Central');
    });

    test('an unnamed pin does NOT fall back to coordinates', () {
      // Coordinates say nothing at a glance and are the one part worth not
      // scattering through quote lines, search hits and notifications.
      const pin = LocationEnvelope(latitude: 48.2, longitude: 16.37);
      final label = placePreviewLabel(pin.encode())!;
      expect(label.contains('48.2'), isFalse);
      expect(label.contains('16.37'), isFalse);
    });

    test('an event shows its title', () {
      final event = EventEnvelope(
        title: 'Abendessen mit Sebi',
        start: DateTime.utc(2026, 8, 14, 19),
      );
      expect(placePreviewLabel(event.encode()), '\u{1F4C5} Abendessen mit Sebi');
    });

    test('anything else stays null so callers keep their own text', () {
      expect(placePreviewLabel('ganz normaler Text'), isNull);
      expect(placePreviewLabel(null), isNull);
      expect(placePreviewLabel('{"_chattr_media":1}'), isNull);
    });
  });

  group('verbatimPlaceEnvelope', () {
    // The iOS share extension (share_handler fork p1) reads an Apple Maps place
    // NATIVELY and passes `_chattr_location` straight through as shared text —
    // name and address included, which no link would carry.
    const pin =
        '{"_chattr_location":1,"lat":48.2082,"lon":16.3738,'
        '"name":"Stephansdom","address":"Stephansplatz 3, 1010 Wien"}';

    test('accepts a finished place envelope unchanged', () {
      final out = verbatimPlaceEnvelope(pin);
      expect(out, isNotNull);
      final parsed = LocationEnvelope.tryParse(out)!;
      expect(parsed.name, 'Stephansdom');
      expect(parsed.address, 'Stephansplatz 3, 1010 Wien');
    });

    test('finds it beside a link sent along too', () {
      // Apple often attaches BOTH, and the extension joins shared texts with a
      // line break. Without this line search the whole thing would no longer be
      // valid JSON — and the fallback to the link would lose name and address.
      final out = verbatimPlaceEnvelope(
        '$pin\nhttps://maps.apple.com/?ll=48.2082,16.3738',
      );
      expect(LocationEnvelope.tryParse(out)!.name, 'Stephansdom');
    });

    test('accepts an appointment envelope as well', () {
      final out = verbatimPlaceEnvelope(
        '{"_chattr_event":1,"title":"Abendessen",'
        '"start":"2026-08-14T19:00:00.000Z"}',
      );
      expect(EventEnvelope.tryParse(out)!.title, 'Abendessen');
    });

    test('leaves ordinary shared text alone', () {
      expect(verbatimPlaceEnvelope('Schau mal hier'), isNull);
      expect(
        verbatimPlaceEnvelope('https://maps.apple.com/?ll=48.2,16.3'),
        isNull,
        reason: 'a link belongs to parseSharedLocation, not here',
      );
      expect(verbatimPlaceEnvelope('{"hello":"world"}'), isNull);
      expect(verbatimPlaceEnvelope(''), isNull);
      expect(verbatimPlaceEnvelope(null), isNull);
    });
  });

  group('openUris — where a tap goes', () {
    final pin = LocationEnvelope(
      latitude: 48.2082,
      longitude: 16.3738,
      name: 'Stephansdom',
    );

    test('on Apple systems maps:// leads the list', () {
      // iOS does NOT register `geo:` at all. If it stood first, the attempt
      // failed and the shared place ended up on the OpenStreetMap WEBSITE
      // instead of in Maps (reported by Gerry on the iPhone, 2026-08-13).
      final uris = pin.openUris(isApple: true);
      expect(uris.first, startsWith('maps://'));
      expect(uris.first, contains('ll=48.2082,16.3738'));
      expect(uris.first, contains('q=Stephansdom'));
    });

    test('otherwise geo: leads — that is the Android picker', () {
      expect(pin.openUris(isApple: false).first, startsWith('geo:'));
    });

    test('the website is the last resort everywhere, never the first', () {
      for (final apple in [true, false]) {
        final uris = pin.openUris(isApple: apple);
        expect(uris.last, contains('openstreetmap.org'));
        expect(uris.length, greaterThan(1));
      }
    });

    test('on Apple too geo: stays as an intermediate step', () {
      // An installed third-party maps app may claim the scheme — that is closer
      // to "the user's app" than a website.
      expect(pin.openUris(isApple: true)[1], startsWith('geo:'));
    });

    test('without a name the address stays empty rather than invented', () {
      final bare = LocationEnvelope(latitude: 1.5, longitude: 2.5);
      expect(bare.toAppleMapsUri(), 'maps://?ll=1.5,2.5');
      expect(bare.toGeoUri(), 'geo:1.5,2.5');
    });
  });

  group('note — the comment on the place', () {
    test('travels inside the envelope, not as a second message', () {
      // Deliberate: a comment arriving without its place — or a place whose
      // comment has scrolled away — would be worse than none.
      final pin = LocationEnvelope(
        latitude: 48.2082,
        longitude: 16.3738,
        name: 'Stephansdom',
      ).withNote('20:30 dort?');

      final back = LocationEnvelope.tryParse(pin.encode())!;
      expect(back.note, '20:30 dort?');
      expect(back.name, 'Stephansdom');
      expect(back.latitude, 48.2082);
    });

    test('an empty comment leaves no field behind', () {
      final bare = LocationEnvelope(latitude: 1, longitude: 2).withNote('');
      expect(bare.note, isNull);
      expect(bare.encode(), isNot(contains('note')));
    });

    test('auch am Termin', () {
      final event = EventEnvelope(
        title: 'Abendessen',
        start: DateTime.utc(2026, 8, 14, 19),
      ).withNote('Ich reserviere');
      expect(EventEnvelope.tryParse(event.encode())!.note, 'Ich reserviere');
    });

    test('an envelope without a note stays valid', () {
      // Older senders (and the iOS extension) send no note field.
      final old = LocationEnvelope.tryParse(
        '{"_chattr_location":1,"lat":1.0,"lon":2.0}',
      )!;
      expect(old.note, isNull);
    });
  });
}
