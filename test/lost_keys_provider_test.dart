// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chattr/features/chats/lost_keys_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LostKeysNotifier (#11)', () {
    test('markLost adds a chat and is idempotent', () {
      final n = LostKeysNotifier();
      expect(n.isLost('c1'), isFalse);
      n.markLost('c1');
      expect(n.isLost('c1'), isTrue);
      expect(n.state, {'c1'});
      // Idempotent: same state instance-of-value, no duplicate.
      n.markLost('c1');
      expect(n.state, {'c1'});
    });

    test('clear removes only the given chat', () {
      final n = LostKeysNotifier()
        ..markLost('a')
        ..markLost('b');
      expect(n.state, {'a', 'b'});
      n.clear('a');
      expect(n.isLost('a'), isFalse);
      expect(n.isLost('b'), isTrue);
      // Clearing an untracked chat is a no-op.
      n.clear('nope');
      expect(n.state, {'b'});
    });
  });
}
