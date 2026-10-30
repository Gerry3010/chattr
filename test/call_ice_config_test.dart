// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// What the server's ICE list (get_call_ice_servers, 00086) turns into on the
// device. Malformed entries are dropped one by one, never the whole list.

import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/features/calls/call_ice_config.dart';

void main() {
  test('die Antwort des Servers wird übernommen', () {
    final out = parseIceServers([
      {
        'urls': ['stun:t:3478']
      },
      {
        'urls': ['turn:t:3478?transport=udp', 'turn:t:3478?transport=tcp'],
        'username': '1:ab',
        'credential': 'xyz',
      },
    ]);
    expect(out, hasLength(2));
    expect(out[0].containsKey('credential'), isFalse);
    expect(out[1]['urls'], hasLength(2));
    expect(out[1]['credential'], 'xyz');
  });

  test('kaputte Einträge fallen einzeln weg', () {
    final out = parseIceServers([
      'quatsch',
      {'urls': 'stun:kein-array'},
      {'urls': <String>[]},
      {
        'urls': [1, 2]
      },
      {
        'urls': ['stun:gut:3478']
      },
    ]);
    expect(out.single['urls'], ['stun:gut:3478']);
  });

  test('keine Liste ergibt keine Server', () {
    expect(parseIceServers(null), isEmpty);
    expect(parseIceServers({'urls': []}), isEmpty);
  });
}
